#if DEBUG
    import CryptoKit
    import Foundation

    /// Зависимости одного превью: данные и настройки остаются только в памяти.
    @MainActor
    final class PreviewEnvironment {
        let repository = PreviewProjectRepository()
        let preferences = PreviewPreferenceStore()
        let activity: ActivityCenter

        init() {
            activity = ActivityCenter(
                stageMemory: StageDurationMemory(store: preferences),
                announcer: ActivityAnnouncer(
                    isAppActive: { true }, showBadge: { _ in },
                    playSound: { _ in }, bounceIcon: {}))
            AIProvider.codexCLI.save(in: preferences)
        }

        func makeAIConnection(reasoningKey: String) -> AIConnectionController {
            let connection = AIConnectionController(
                preferences: preferences,
                reasoningPreferenceKey: reasoningKey,
                openRouter: OpenRouterClient(),
                keyStore: EmptyOpenRouterKeyStore(),
                discovery: { _ in Self.agents },
                allowsNetworkRequests: false)
            connection.refreshAgents()
            return connection
        }

        /// Список уже подготовлен; поиск установленных программ не запускается.
        nonisolated static let agents: [AIAgentAvailability] = [
            .openRouter,
            AIAgentAvailability(
                provider: .codexCLI, isAvailable: false, executablePath: nil,
                models: [AIModelOption(id: AIProvider.codexCLI.fallbackModelID)],
                message: "Изолированное превью"),
            AIAgentAvailability(
                provider: .openCodeCLI, isAvailable: false, executablePath: nil,
                models: [AIModelOption(id: AIProvider.openCodeCLI.fallbackModelID)],
                message: "Изолированное превью"),
        ]
    }

    /// URL нужны контроллерам для зависимостей, но папки никогда не создаются.
    final class PreviewProjectRepository: ProjectRepository, @unchecked Sendable {
        let root = URL(fileURLWithPath: "/tmp/montazhka-preview-\(UUID().uuidString)", isDirectory: true)
        let directories: ProjectDirectories
        private let lock = NSLock()
        private var projects: [UUID: Project] = [:]
        private var revisions: [UUID: ProjectRevision] = [:]
        private var accesses = 0

        init() {
            directories = ProjectDirectories(
                projects: root.appendingPathComponent("Projects"),
                waveforms: root.appendingPathComponent("Waveforms"),
                enhancedAudio: root.appendingPathComponent("EnhancedAudio"),
                musicEQ: root.appendingPathComponent("MusicEQ"),
                transcripts: root.appendingPathComponent("Transcripts"),
                models: root.appendingPathComponent("Models"),
                shortsAnalysis: root.appendingPathComponent("ShortsAnalysis"))
        }

        var accessCount: Int { lock.withLock { accesses } }

        func save(_ project: Project) async throws {
            try lock.withLock {
                accesses += 1
                store(project, revision: try Self.revision(for: project))
            }
        }

        func save(_ project: Project, expected: ProjectRevision?) async throws -> ProjectRevision {
            try saveBeforeTermination(project, expected: expected)
        }

        func load(id: UUID) async throws -> Project {
            try await loadWithRevision(id: id).project
        }

        func loadWithRevision(id: UUID) async throws -> (project: Project, revision: ProjectRevision) {
            try lock.withLock {
                accesses += 1
                guard let project = projects[id], let revision = revisions[id] else {
                    throw ProjectStoreError.read("Preview project not found")
                }
                return (project, revision)
            }
        }

        func delete(id: UUID) async throws {
            lock.withLock {
                accesses += 1
                projects[id] = nil
                revisions[id] = nil
            }
        }

        func listProjects() async throws -> ProjectListing {
            lock.withLock {
                accesses += 1
                let metadata = projects.values.map {
                    ProjectMeta(
                        id: $0.id, name: $0.name, updatedAt: $0.updatedAt,
                        duration: $0.totalDuration, clipCount: $0.clips.count)
                }.sorted { $0.updatedAt > $1.updatedAt }
                return ProjectListing(projects: metadata, issues: [])
            }
        }

        func saveBeforeTermination(_ project: Project, expected: ProjectRevision?) throws -> ProjectRevision {
            try lock.withLock {
                accesses += 1
                guard revisions[project.id] == expected else { throw ProjectStoreError.conflict }
                let revision = try Self.revision(for: project)
                store(project, revision: revision)
                return revision
            }
        }

        func revision(of id: UUID) -> ProjectRevision? {
            lock.withLock {
                accesses += 1
                return revisions[id]
            }
        }

        private func store(_ project: Project, revision: ProjectRevision) {
            projects[project.id] = project
            revisions[project.id] = revision
        }

        private static func revision(for project: Project) throws -> ProjectRevision {
            let digest = SHA256.hash(data: try ProjectStore.encoded(project))
            return ProjectRevision(digest: digest.map { String(format: "%02x", $0) }.joined())
        }
    }

    final class PreviewPreferenceStore: PreferenceStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var strings: [String: String] = [:]
        private var bools: [String: Bool] = [:]

        func string(forKey key: String) -> String? { lock.withLock { strings[key] } }
        func set(_ value: String?, forKey key: String) { lock.withLock { strings[key] = value } }
        func bool(forKey key: String) -> Bool { lock.withLock { bools[key] ?? false } }
        func set(_ value: Bool, forKey key: String) { lock.withLock { bools[key] = value } }
    }
#endif
