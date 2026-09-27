import Foundation

enum AgentRunKind: String, Codable, Sendable {
    case editVideo
    case editProject
    case makeShorts
    case export
    case transcribe
}

enum AgentRunStatus: String, Codable, Sendable {
    case pending
    case running
    case waitingForApproval
    case completed
    case failed

    /// Работа закончена — поздние события прогресса статус уже не меняют.
    var isFinished: Bool { self == .completed || self == .failed }
}

struct AgentRun: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let kind: AgentRunKind
    var status: AgentRunStatus
    var sourcePaths: [String]
    let createdAt: Date
    var updatedAt: Date
    var progress: Double
    var stage: String?
    var projectID: UUID?
    var summary: String?
    var artifacts: [String: String]
    var error: AgentErrorPayload?
    /// Замок процесса, который выполняет задачу; nil — исполнитель ещё не взялся (или старая запись).
    var executorLock: String?
}

enum AgentRunStoreError: LocalizedError {
    case notFound(UUID)

    var errorDescription: String? {
        switch self {
        case .notFound(let id): "Задача \(id.uuidString) не найдена."
        }
    }
}

actor AgentRunStore {
    /// Сколько ждать, пока запущенный фоновый процесс возьмёт задачу.
    static let workerStartGrace: TimeInterval = 60

    let baseDirectory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    /// Задачи, которые выполняет этот процесс: их замки держатся до конца работы.
    private var claims: [UUID: FileLock] = [:]

    init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func create(kind: AgentRunKind, sourcePaths: [String]) throws -> AgentRun {
        let now = Date()
        let run = AgentRun(
            id: UUID(), kind: kind, status: .pending, sourcePaths: sourcePaths,
            createdAt: now, updatedAt: now, progress: 0, stage: nil,
            projectID: nil, summary: nil, artifacts: [:], error: nil)
        try save(run)
        return run
    }

    func load(id: UUID) throws -> AgentRun {
        let url = fileURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AgentRunStoreError.notFound(id)
        }
        return try decoder.decode(AgentRun.self, from: Data(contentsOf: url))
    }

    func update(id: UUID, _ change: (inout AgentRun) -> Void) throws {
        let before = try load(id: id)
        var run = before
        change(&run)
        // Итог законченной задачи окончателен: поздние события прогресса и поздняя сверка
        // (в том числе из другого процесса) не меняют ни статус, ни этап, ни описание.
        // Дописать можно только итоговые файлы.
        if before.status.isFinished {
            run.status = before.status
            run.progress = before.progress
            run.stage = before.stage
            run.summary = before.summary
            run.error = before.error
        }
        run.updatedAt = Date()
        try save(run)
        if run.status.isFinished { claims[id] = nil }
    }

    /// Этот процесс выполняет задачу: он держит её замок, пока задача не закончится или
    /// пока сам процесс жив. Упадёт процесс — замок снимет система, и `reconcile` это увидит.
    func claim(id: UUID) throws {
        guard claims[id] == nil else { return }
        let url = try artifactDirectory(id: id).appendingPathComponent("worker.lock")
        claims[id] = try FileLock(lockFile: url, wait: false)
        try update(id: id) { $0.executorLock = url.path }
    }

    /// Задача, чей исполнитель умер, получает честный конечный статус. Живой исполнитель
    /// держит замок сколько угодно долго — долгий рендер ложной ошибки не получает.
    /// Исполнитель, который так и не взялся за задачу за `workerStartGrace`, тоже умер.
    func reconcile(id: UUID) throws -> AgentRun {
        let run = try load(id: id)
        guard run.status == .running || run.status == .pending else { return run }
        let interrupted: Bool
        if let lock = run.executorLock {
            interrupted = !FileLock.isHeld(lockFile: URL(fileURLWithPath: lock))
        } else {
            interrupted = Date().timeIntervalSince(run.updatedAt) > Self.workerStartGrace
        }
        guard interrupted else { return run }
        try update(id: id) {
            // Исполнитель мог успеть закончить между чтением и этой записью.
            guard $0.status == .running || $0.status == .pending else { return }
            $0.status = .failed
            $0.stage = "Прервано"
            $0.summary =
                "Фоновый процесс прервался (закрылся, упал или компьютер перезагрузился). "
                + "Запустите задачу заново — уже созданные файлы остаются на месте."
            $0.error = AgentErrorPayload(code: "WORKER_INTERRUPTED", message: $0.summary ?? "")
        }
        return try load(id: id)
    }

    /// Сверка всех незаконченных задач — при запуске приложения.
    func reconcileAll() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: baseDirectory.path)) ?? []
        for id in names.compactMap(UUID.init(uuidString:)) { _ = try? reconcile(id: id) }
    }

    func artifactDirectory(id: UUID) throws -> URL {
        let directory = baseDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func save(_ run: AgentRun) throws {
        let directory = try artifactDirectory(id: run.id)
        try encoder.encode(run).write(
            to: directory.appendingPathComponent("run.json"), options: .atomic)
    }

    private func fileURL(_ id: UUID) -> URL {
        baseDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent("run.json")
    }
}
