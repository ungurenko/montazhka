import Darwin
import Foundation

/// Межпроцессная блокировка на время «прочитать → изменить → записать» общего файла:
/// ждёт, пока другой процесс или экземпляр допишет своё. Держится, пока жив объект.
final class FileLock {
    private let descriptor: Int32

    /// Замок рядом с файлом: `<файл>.lock`.
    convenience init(guarding target: URL) throws {
        try self.init(lockFile: target.appendingPathExtension("lock"))
    }

    init(lockFile: URL) throws {
        try FileManager.default.createDirectory(
            at: lockFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = Darwin.open(lockFile.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: lockFile.path])
        }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                Darwin.close(descriptor)
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: lockFile.path])
            }
        }
        self.descriptor = descriptor
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
}
