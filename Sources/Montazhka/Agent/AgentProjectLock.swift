import Darwin
import Foundation

enum AgentProjectLockError: LocalizedError {
    case busy(UUID)

    var errorDescription: String? {
        switch self {
        case .busy(let id): "Проект \(id.uuidString) уже изменяется в другом процессе."
        }
    }
}

/// Межпроцессная блокировка: один проект одновременно меняет только один процесс.
final class AgentProjectLock: @unchecked Sendable {
    private let descriptor: Int32

    init(projectID: UUID, directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(projectID.uuidString).lock")
        descriptor = Darwin.open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if descriptor >= 0 { Darwin.close(descriptor) }
            throw AgentProjectLockError.busy(projectID)
        }
    }

    deinit {
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}
