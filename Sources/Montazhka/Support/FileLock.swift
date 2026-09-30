import Darwin
import Foundation

/// Межпроцессная блокировка на время «прочитать → изменить → записать» общего файла:
/// ждёт, пока другой процесс или экземпляр допишет своё. Держится, пока жив объект.
final class FileLock {
    /// Замок уже держит другой процесс или экземпляр (при `wait: false`).
    struct Busy: Error {}

    private let descriptor: Int32

    /// Замок рядом с файлом: `<файл>.lock`.
    convenience init(guarding target: URL) throws {
        try self.init(lockFile: target.appendingPathExtension("lock"))
    }

    /// `wait: false` — не ждать: занято — `Busy`.
    init(lockFile: URL, wait: Bool = true) throws {
        try FileManager.default.createDirectory(
            at: lockFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = Darwin.open(lockFile.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: lockFile.path])
        }
        while flock(descriptor, wait ? LOCK_EX : LOCK_EX | LOCK_NB) != 0 {
            let reason = errno
            guard reason == EINTR else {
                Darwin.close(descriptor)
                if reason == EWOULDBLOCK { throw Busy() }
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: lockFile.path])
            }
        }
        self.descriptor = descriptor
    }

    /// Держит ли кто-то замок сейчас. Замок процесса снимает сама система, когда процесс
    /// завершается любым способом, — поэтому «не держит» значит «держателя больше нет».
    static func isHeld(lockFile: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: lockFile.path) else { return false }
        do {
            _ = try FileLock(lockFile: lockFile, wait: false)
            return false
        } catch is Busy {
            return true
        } catch {
            return false
        }
    }

    deinit {
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }

    static func withLock<T>(guarding target: URL, _ body: () throws -> T) throws -> T {
        let lock = try FileLock(guarding: target)
        defer { withExtendedLifetime(lock) {} }
        return try body()
    }

    static func acquire(guarding target: URL) async throws -> FileLock {
        while true {
            try Task.checkCancellation()
            do { return try FileLock(lockFile: target.appendingPathExtension("lock"), wait: false) } catch is Busy {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    static func acquireSlot(in directory: URL, count: Int) async throws -> FileLock {
        while true {
            try Task.checkCancellation()
            for index in 0..<count {
                do {
                    return try FileLock(lockFile: directory.appendingPathComponent("worker-\(index).lock"), wait: false)
                } catch is Busy { continue }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
