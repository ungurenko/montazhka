import Darwin
import Foundation
import ObjectiveC

/// Удержание файла кэша, пока его читает склейка: общая блокировка `flock` видна
/// и другим процессам — окно и агент делят папку кэша. Уборка удаляет только файлы,
/// которые никто не держит (`removeIfUnused`).
final class CacheFileLease: @unchecked Sendable {
    private let descriptor: Int32

    /// nil — файла нет (или его как раз убрали).
    init?(url: URL) {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        // Ждёт только уборку, которая держит файл долю секунды перед удалением.
        while flock(descriptor, LOCK_SH) != 0 {
            guard errno == EINTR else {
                Darwin.close(descriptor)
                return nil
            }
        }
        // Пока ждали, уборка могла удалить файл: держать уже нечего.
        var held = stat()
        var current = stat()
        guard fstat(descriptor, &held) == 0, stat(url.path, &current) == 0,
            held.st_dev == current.st_dev, held.st_ino == current.st_ino
        else {
            Darwin.close(descriptor)
            return nil
        }
        self.descriptor = descriptor
    }

    deinit {
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }

    /// Удаляет файл, если его никто не держит. true — удалён.
    @discardableResult
    static func removeIfUnused(_ url: URL) -> Bool {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return false }
        return unlink(url.path) == 0
    }
}

nonisolated(unsafe) private let leasesKey = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)

extension CacheFileLease {
    /// Удержания живут, пока жив `owner` — склейка, которую держат плеер и экспорт.
    static func attach(_ leases: [CacheFileLease], to owner: AnyObject) {
        guard !leases.isEmpty else { return }
        objc_setAssociatedObject(owner, leasesKey, leases, .OBJC_ASSOCIATION_RETAIN)
    }
}
