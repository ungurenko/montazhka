import Foundation

enum AgentEditProfile: String, Codable, Sendable {
    case cleanSpeech = "clean-speech"
    case dynamic
    case shorts
}

enum AgentAIMode: String, Codable, Sendable {
    case off
    case builtIn = "built-in"
    case external
}

struct AgentSourceCut: Codable, Equatable, Sendable {
    let sourcePath: String
    let start: Double
    let end: Double
}

struct AgentEditRequest: Codable, Sendable {
    var sourcePaths: [String]
    var projectID: UUID?
    var name: String?
    var profile: AgentEditProfile = .cleanSpeech
    var cuts: [AgentSourceCut] = []
    var removePauses = true
    var enhanceVoice = true
    var musicPath: String?
    var aiMode: AgentAIMode = .off
    var confirmModelDownload = false

    init(
        sourcePaths: [String], projectID: UUID? = nil, name: String? = nil,
        profile: AgentEditProfile = .cleanSpeech, cuts: [AgentSourceCut] = [],
        removePauses: Bool = true, enhanceVoice: Bool = true, musicPath: String? = nil,
        aiMode: AgentAIMode = .off, confirmModelDownload: Bool = false
    ) {
        self.sourcePaths = sourcePaths
        self.projectID = projectID
        self.name = name
        self.profile = profile
        self.cuts = cuts
        self.removePauses = removePauses
        self.enhanceVoice = enhanceVoice
        self.musicPath = musicPath
        self.aiMode = aiMode
        self.confirmModelDownload = confirmModelDownload
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sourcePaths = try values.decodeIfPresent([String].self, forKey: .sourcePaths) ?? []
        projectID = try values.decodeIfPresent(UUID.self, forKey: .projectID)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        profile = try values.decodeIfPresent(AgentEditProfile.self, forKey: .profile) ?? .cleanSpeech
        cuts = try values.decodeIfPresent([AgentSourceCut].self, forKey: .cuts) ?? []
        removePauses = try values.decodeIfPresent(Bool.self, forKey: .removePauses) ?? true
        enhanceVoice = try values.decodeIfPresent(Bool.self, forKey: .enhanceVoice) ?? true
        musicPath = try values.decodeIfPresent(String.self, forKey: .musicPath)
        aiMode =
            try values.decodeIfPresent(AgentAIMode.self, forKey: .aiMode)
            ?? ((try values.decodeIfPresent(Bool.self, forKey: .smartEdit)) == true ? .builtIn : .off)
        confirmModelDownload = try values.decodeIfPresent(Bool.self, forKey: .confirmModelDownload) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case sourcePaths, projectID, name, profile, cuts, removePauses, enhanceVoice
        case musicPath, aiMode, smartEdit, confirmModelDownload
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(sourcePaths, forKey: .sourcePaths)
        try values.encodeIfPresent(projectID, forKey: .projectID)
        try values.encodeIfPresent(name, forKey: .name)
        try values.encode(profile, forKey: .profile)
        try values.encode(cuts, forKey: .cuts)
        try values.encode(removePauses, forKey: .removePauses)
        try values.encode(enhanceVoice, forKey: .enhanceVoice)
        try values.encodeIfPresent(musicPath, forKey: .musicPath)
        try values.encode(aiMode, forKey: .aiMode)
        try values.encode(confirmModelDownload, forKey: .confirmModelDownload)
    }
}

enum AgentServiceError: LocalizedError {
    case invalidInput(String)
    case missingFile(String)
    case emptyProject
    case finalApprovalRequired
    case outputExists(String)
    case runKindMismatch

    var errorDescription: String? {
        switch self {
        case .invalidInput(let value): value
        case .missingFile(let path): "Файл недоступен: \(path)"
        case .emptyProject: "В проекте нет доступных видео."
        case .finalApprovalRequired: "Финальный экспорт требует confirmFinal=true."
        case .outputExists(let path): "Файл уже существует: \(path)"
        case .runKindMismatch: "Тип фоновой задачи не совпадает с операцией."
        }
    }
}

enum AgentRunMode: Sendable {
    case standalone
    case existing(UUID)
}

private struct AgentResourcePage: Encodable {
    let uri: String
    let offset: Int
    let totalBytes: Int
    let content: String
    let nextUri: String?
}

actor AgentService {
    let store: ProjectStore
    let runs: AgentRunStore
    let waveforms: WaveformStore

    var transcriptionModelsDirectory: URL {
        AgentModelLocator.findCompatibleModel()?.deletingLastPathComponent() ?? store.modelsDir
    }

    init(baseDirectory: URL? = nil) {
        store = ProjectStore(baseDirectory: baseDirectory)
        let base =
            baseDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Montazhka", isDirectory: true)
        runs = AgentRunStore(baseDirectory: base.appendingPathComponent("AgentRuns", isDirectory: true))
        waveforms = WaveformStore(cacheDir: store.waveformsDir)
    }

    func doctor() async -> AgentResponse {
        let model = AgentModelLocator.findCompatibleModel()
        let writable = FileManager.default.isWritableFile(atPath: store.projectsDir.path)
        return .success(
            command: "doctor",
            data: [
                "ready": .bool(writable),
                "architecture": .string(Self.architecture),
                "transcriptionSupported": .bool(Self.architecture == "arm64"),
                "modelReady": .bool(model != nil),
                "modelPath": model.map { .string($0.path) } ?? .null,
                "projectsDirectory": .string(store.projectsDir.path),
                "catalogTokens": .number(Double(AgentToolCatalog.estimatedTokenCount)),
            ])
    }

    func projects(id: UUID? = nil, offset: Int = 0, limit: Int = 20) async -> AgentResponse {
        do {
            if let id {
                let project = try await store.load(id: id)
                return .success(command: "get_projects", data: projectData(project))
            }
            let listing = try await store.listProjects()
            let page = Array(listing.projects.dropFirst(max(0, offset)).prefix(min(100, max(1, limit))))
            return .success(
                command: "get_projects",
                data: [
                    "total": .number(Double(listing.projects.count)),
                    "projects": .array(
                        page.map { meta in
                            .object([
                                "id": .string(meta.id.uuidString), "name": .string(meta.name),
                                "duration": .number(meta.duration), "clipCount": .number(Double(meta.clipCount)),
                            ])
                        }),
                    "issues": .number(Double(listing.issues.count)),
                ])
        } catch { return failure("get_projects", error) }
    }

    func job(id: UUID) async -> AgentResponse {
        do {
            let run = try await runs.load(id: id)
            let artifacts = Dictionary(
                uniqueKeysWithValues: run.artifacts.keys.sorted().map {
                    ($0, AgentJSONValue.string("montazhka://runs/\(id.uuidString)/\($0)"))
                })
            return .success(
                command: "get_job",
                data: [
                    "jobId": .string(id.uuidString), "status": .string(run.status.rawValue),
                    "progress": .number(run.progress), "stage": run.stage.map { .string($0) } ?? .null,
                    "projectId": run.projectID.map { .string($0.uuidString) } ?? .null,
                    "summary": run.summary.map { .string($0) } ?? .null,
                    "artifacts": .object(artifacts),
                ])
        } catch { return failure("get_job", error) }
    }

    func inspect(projectID: UUID, around cuts: [Double] = []) async -> AgentResponse {
        do {
            let project = try await store.load(id: projectID)
            let missing = Set(project.clips.map(\.sourcePath)).filter { !FileManager.default.fileExists(atPath: $0) }
            return .success(
                command: "inspect",
                data: [
                    "projectId": .string(project.id.uuidString), "duration": .number(project.totalDuration),
                    "clipCount": .number(Double(project.clips.count)),
                    "missingFiles": .array(missing.sorted().map { .string($0) }),
                    "cutChecks": .array(
                        cuts.prefix(50).map {
                            .object([
                                "time": .number($0), "from": .number(max(0, $0 - 1.5)), "to": .number($0 + 1.5),
                            ])
                        }),
                ])
        } catch { return failure("inspect", error) }
    }

    func resource(uri: String, offset: Int? = nil, limit: Int? = nil) async throws -> String {
        guard uri.hasPrefix("montazhka://runs/"),
            let url = URL(string: uri), url.pathComponents.count >= 3,
            let id = UUID(uuidString: url.host == "runs" ? url.pathComponents[1] : url.pathComponents[2])
        else { throw AgentServiceError.invalidInput("Неверный адрес ресурса.") }
        let run = try await runs.load(id: id)
        let name = url.lastPathComponent
        guard let path = run.artifacts[name], FileManager.default.fileExists(atPath: path) else {
            throw AgentServiceError.invalidInput("Ресурс \(name) не найден.")
        }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let requestedOffset = offset ?? query.firstValue(named: "offset").flatMap(Int.init) ?? 0
        let requestedLimit = limit ?? query.firstValue(named: "limit").flatMap(Int.init) ?? 32_000
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        var start = min(max(0, requestedOffset), data.count)
        while start < data.count, Self.isUTF8Continuation(data[start]) { start += 1 }
        var end = min(data.count, start + min(64_000, max(1, requestedLimit)))
        while end < data.count, Self.isUTF8Continuation(data[end]) { end += 1 }
        let nextURI =
            end < data.count ? "montazhka://runs/\(id.uuidString)/\(name)?offset=\(end)&limit=\(requestedLimit)" : nil
        let page = AgentResourcePage(
            uri: uri, offset: start, totalBytes: data.count,
            content: String(decoding: data[start..<end], as: UTF8.self), nextUri: nextURI)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(page), as: UTF8.self)
    }

    func beginRun(
        mode: AgentRunMode, kind: AgentRunKind, sourcePaths: [String],
        stage: String, projectID: UUID? = nil
    ) async throws -> AgentRun {
        let run: AgentRun
        switch mode {
        case .standalone:
            run = try await runs.create(kind: kind, sourcePaths: sourcePaths)
        case .existing(let id):
            run = try await runs.load(id: id)
            guard run.kind == kind else { throw AgentServiceError.runKindMismatch }
        }
        try await runs.update(id: run.id) {
            $0.status = .running
            $0.stage = stage
            $0.sourcePaths = sourcePaths
            $0.projectID = projectID
            $0.error = nil
        }
        return try await runs.load(id: run.id)
    }

    func failRun(id: UUID, error: Error) async {
        try? await runs.update(id: id) {
            $0.status = .failed
            $0.stage = "Ошибка"
            $0.summary = error.localizedDescription
            $0.error = AgentErrorPayload(
                code: String(describing: type(of: error)),
                message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func projectData(_ project: Project) -> [String: AgentJSONValue] {
        [
            "id": .string(project.id.uuidString), "name": .string(project.name),
            "duration": .number(project.totalDuration), "clipCount": .number(Double(project.clips.count)),
            "sourcePaths": .array(Array(Set(project.clips.map(\.sourcePath))).sorted().map { .string($0) }),
        ]
    }

    func failure(_ command: String, _ error: Error) -> AgentResponse {
        .failure(
            command: command, code: String(describing: type(of: error)),
            message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }

    private static var architecture: String {
        #if arch(arm64)
            "arm64"
        #else
            "x86_64"
        #endif
    }

    private static func isUTF8Continuation(_ byte: UInt8) -> Bool {
        byte & 0b1100_0000 == 0b1000_0000
    }
}

private extension [URLQueryItem] {
    func firstValue(named name: String) -> String? {
        first { $0.name == name }?.value
    }
}

enum AgentAIConfigurationResolver {
    static func resolve(
        reasoningKey: String,
        preferences: any PreferenceStoring = UserDefaultsPreferenceStore.standard
    ) async throws -> AIRequestConfiguration {
        let provider = AIProvider.saved(in: preferences)
        let modelID = provider.savedModelID(in: preferences)
        let effort = ReasoningChoice.saved(key: reasoningKey, in: preferences).apiEffort
        switch provider {
        case .openRouter:
            guard let model = SmartEditModel(rawValue: modelID) else {
                throw AIProviderError.modelUnavailable(modelID)
            }
            guard let key = try await OpenRouterKeyStore().load() else {
                throw AIProviderError.missingCredential("OpenRouter")
            }
            return .openRouter(model: model, effort: effort, apiKey: key)
        case .codexCLI, .openCodeCLI:
            let agents = await AIAgentDiscovery.shared.discover(force: true)
            guard let agent = agents.first(where: { $0.provider == provider }),
                agent.isAvailable, agent.models.contains(where: { $0.id == modelID }),
                let path = agent.executablePath
            else {
                throw AIProviderError.agentUnavailable(provider.title)
            }
            let executable = URL(fileURLWithPath: path)
            return provider == .codexCLI
                ? .codexCLI(modelID: modelID, effort: effort, executable: executable)
                : .openCodeCLI(modelID: modelID, effort: effort, executable: executable)
        }
    }
}

enum AgentModelLocator {
    private static let required = [
        "Encoder.mlmodelc", "Decoder.mlmodelc", "Preprocessor.mlmodelc", "JointDecisionv3.mlmodelc", "config.json",
    ]

    static func findCompatibleModel(in applicationSupport: URL? = nil) -> URL? {
        let support =
            applicationSupport
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let candidates = [
            support.appendingPathComponent("Montazhka/parakeet-tdt-0.6b-v3"),
            support.appendingPathComponent("Montazhka/Models/parakeet-tdt-0.6b-v3"),
            support.appendingPathComponent("FluidAudio/Models/parakeet-tdt-0.6b-v3"),
        ]
        return candidates.first { candidate in
            required.allSatisfy {
                FileManager.default.fileExists(atPath: candidate.appendingPathComponent($0).path)
            }
        }
    }
}
