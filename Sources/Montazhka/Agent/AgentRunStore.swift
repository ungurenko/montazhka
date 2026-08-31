import Foundation

enum AgentRunKind: String, Codable, Sendable {
    case editVideo
    case editProject
    case makeShorts
    case export
}

enum AgentRunStatus: String, Codable, Sendable {
    case pending
    case running
    case waitingForApproval
    case completed
    case failed
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
    let baseDirectory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

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
        var run = try load(id: id)
        change(&run)
        run.updatedAt = Date()
        try save(run)
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
