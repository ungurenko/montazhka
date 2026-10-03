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
    private let lock: FileLock

    init(projectID: UUID, directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(projectID.uuidString).lock")
        do {
            lock = try FileLock(lockFile: url, wait: false)
        } catch {
            throw AgentProjectLockError.busy(projectID)
        }
    }
}
