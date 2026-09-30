import Foundation
import OSLog

/// Все чтения выходов одного reader и его отмена выполняются на одной очереди.
/// Запрос отмены виден сразу, но системный cancel ждёт завершения текущего чтения.
final class MediaReaderPumpQueue: @unchecked Sendable {
    let queue: DispatchQueue
    private let requested = OSAllocatedUnfairLock(initialState: false)
    private let cancelReader: @Sendable () -> Void
    // Только на queue, включая регистрацию обработчиков.
    private var stopped = false
    private var handlers: [(id: UUID, action: @Sendable () -> Void)] = []

    init(label: String, cancelReader: @escaping @Sendable () -> Void) {
        queue = DispatchQueue(label: label)
        self.cancelReader = cancelReader
    }

    var isCancelled: Bool { requested.withLock { $0 } }

    func cancel() {
        let first = requested.withLock { value in
            guard !value else { return false }
            value = true
            return true
        }
        guard first else { return }
        queue.async { self.stopOnQueue() }
    }

    func stopOnQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
        requested.withLock { $0 = true }
        guard !stopped else { return }
        stopped = true
        cancelReader()
        let handlers = handlers
        self.handlers.removeAll()
        for handler in handlers { handler.action() }
    }

    /// Вызывать на queue. Поздно зарегистрированная дорожка тоже завершается.
    @discardableResult
    func onCancel(_ handler: @escaping @Sendable () -> Void) -> UUID {
        dispatchPrecondition(condition: .onQueue(queue))
        let id = UUID()
        if stopped {
            handler()
        } else {
            handlers.append((id, handler))
        }
        return id
    }

    func removeHandler(_ id: UUID?) {
        dispatchPrecondition(condition: .onQueue(queue))
        handlers.removeAll { $0.id == id }
    }

    func removeHandlers() {
        dispatchPrecondition(condition: .onQueue(queue))
        handlers.removeAll()
    }
}
