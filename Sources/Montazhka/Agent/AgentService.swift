import CryptoKit
import Foundation
import UniformTypeIdentifiers

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
        sourcePaths = values.contains(.sourcePaths) ? try values.decode([String].self, forKey: .sourcePaths) : []
        // В MCP поле называется projectId — принимаем и его, чтобы JSON для CLI был тем же.
        projectID =
            try values.decodeIfPresent(UUID.self, forKey: .projectID)
            ?? values.decodeIfPresent(UUID.self, forKey: .projectId)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        profile = values.contains(.profile) ? try values.decode(AgentEditProfile.self, forKey: .profile) : .cleanSpeech
        cuts = values.contains(.cuts) ? try values.decode([AgentSourceCut].self, forKey: .cuts) : []
        removePauses = values.contains(.removePauses) ? try values.decode(Bool.self, forKey: .removePauses) : true
        enhanceVoice = values.contains(.enhanceVoice) ? try values.decode(Bool.self, forKey: .enhanceVoice) : true
        musicPath = try values.decodeIfPresent(String.self, forKey: .musicPath)
        aiMode =
            values.contains(.aiMode)
            ? try values.decode(AgentAIMode.self, forKey: .aiMode)
            : ((try values.decodeIfPresent(Bool.self, forKey: .smartEdit)) == true ? .builtIn : .off)
        confirmModelDownload =
            values.contains(.confirmModelDownload) ? try values.decode(Bool.self, forKey: .confirmModelDownload) : false
    }

    private enum CodingKeys: String, CodingKey {
        case sourcePaths, projectID, projectId, name, profile, cuts, removePauses, enhanceVoice
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

/// Страница текстового ресурса: читается только она — с позиции `offset`, не больше
/// `limit` байт и нескольких байт на границу буквы UTF-8, сколько бы весил файл.
/// Страница не начинается и не кончается посреди буквы. `read` — чтение из открытого
/// файла (в тестах — со счётчиком прочитанного).
enum AgentResourceReader {
    typealias Read = (FileHandle, Int) throws -> Data

    /// Самая длинная буква UTF-8 — 4 байта: хвост дочитывается не дальше.
    private static let letterTail = 3

    static func textPage(
        at url: URL, offset: Int, limit: Int, read: Read = { try $0.read(upToCount: $1) ?? Data() }
    ) throws -> (content: String, start: Int, end: Int, total: Int) {
        let total = try byteCount(of: url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var start = min(max(0, offset), total)
        let length = max(1, limit)
        try handle.seek(toOffset: UInt64(start))
        var window = try read(handle, min(total - start, length + letterTail))
        // Начало посреди буквы — страница начинается со следующей.
        let skipped = window.prefix(letterTail).prefix(while: isContinuation).count
        start += skipped
        window = window.dropFirst(skipped)
        var end = min(total, start + length)
        while end < min(total, start + window.count), isContinuation(window[window.startIndex + (end - start)]) {
            end += 1
        }
        let bytes = window.prefix(end - start)
        return (String(decoding: bytes, as: UTF8.self), start, start + bytes.count, total)
    }

    static func byteCount(of url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    }

    /// Видео, звук и картинки — не текст: их отдают путём и размером.
    static func mediaType(of url: URL) -> UTType? {
        guard let type = UTType(filenameExtension: url.pathExtension),
            type.conforms(to: .audiovisualContent) || type.conforms(to: .image)
        else { return nil }
        return type
    }

    private static func isContinuation(_ byte: UInt8) -> Bool {
        byte & 0b1100_0000 == 0b1000_0000
    }
}

private struct AgentResourcePage: Encodable {
    let uri: String
    /// "text" — страница текста в `content`; "media" — файл по `path`, текстом не читается.
    let kind: String
    let offset: Int
    let totalBytes: Int
    var content: String?
    var nextUri: String?
    var mimeType: String?
    var path: String?
}

/// Запуск фоновой задачи отдельным процессом; тесты подменяют его, чтобы не запускать расшифровку.
typealias AgentJobStarter = @Sendable (AgentWorkerRequest) async throws -> AgentResponse

actor AgentService {
    let store: ProjectStore
    let runs: AgentRunStore
    let waveforms: WaveformStore
    let revisions: AgentRevisionStore
    /// Заметки агента о проектах; в ревизии не входят, поэтому `undo` их не трогает.
    let notes: AgentNotesStore
    let startJob: AgentJobStarter

    var transcriptionModelsDirectory: URL {
        AgentModelLocator.findCompatibleModel()?.deletingLastPathComponent() ?? store.modelsDir
    }

    /// Новое хранилище расшифровок. Внутри него живёт загруженная модель
    /// распознавания, поэтому на одну команду хватает одного экземпляра —
    /// не создавай его в цикле.
    func makeTranscriptStore() -> TranscriptStore {
        TranscriptStore(cacheDir: store.transcriptsDir, modelsDir: transcriptionModelsDirectory)
    }

    /// Модель распознавания весит полгигабайта, поэтому агент не качает её
    /// молча: без явного подтверждения команда возвращает отказ с объяснением.
    /// Ответ есть — значит команду выполнять нельзя.
    func refusalIfModelNeedsDownload(command: String, confirmed: Bool) async -> AgentResponse? {
        guard await !makeTranscriptStore().modelIsCached(), !confirmed else { return nil }
        return .failure(
            command: command, code: "MODEL_DOWNLOAD_REQUIRED",
            message: "Нужна совместимая модель Parakeet Core ML (около 500 МБ).",
            recovery: "Повторите вызов с confirmModelDownload=true.")
    }

    init(
        baseDirectory: URL? = nil, runs suppliedRuns: AgentRunStore? = nil,
        startJob: @escaping AgentJobStarter = { try await AgentBackgroundJob.submit($0) }
    ) {
        store = ProjectStore(baseDirectory: baseDirectory)
        let base =
            baseDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Montazhka", isDirectory: true)
        runs = suppliedRuns ?? AgentRunStore(baseDirectory: base.appendingPathComponent("AgentRuns", isDirectory: true))
        waveforms = WaveformStore(cacheDir: store.waveformsDir)
        revisions = AgentRevisionStore(baseDirectory: base.appendingPathComponent("AgentRevisions", isDirectory: true))
        notes = AgentNotesStore(baseDirectory: base.appendingPathComponent("AgentNotes", isDirectory: true))
        self.startJob = startJob
    }

    func doctor() async -> AgentResponse {
        let model = AgentModelLocator.findCompatibleModel()
        let writable = FileManager.default.isWritableFile(atPath: store.projectsDir.path)
        return .success(
            command: "doctor",
            data: [
                "ready": .bool(writable),
                "version": .string(AgentBuildInfo.version),
                "architecture": .string(Self.architecture),
                "transcriptionSupported": .bool(Self.architecture == "arm64"),
                "modelReady": .bool(model != nil),
                "modelPath": model.map { .string($0.path) } ?? .null,
                "projectsDirectory": .string(store.projectsDir.path),
                "catalogTokens": .number(Double(AgentToolCatalog.estimatedTokenCount)),
                "features": .array(
                    ["source-analysis-v1", "cover-overlay", "freeze-tail", "expected-timeline"].map { .string($0) }),
                "runtimeIdentity": .string(Self.runtimeIdentity),
                "music": .array(MusicLibrary.tracks.map(Self.musicData)),
            ])
    }

    private static var runtimeIdentity: String {
        let path = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return
            "\(AgentBuildInfo.version)|\(path)|\(attrs?[.size] ?? 0)|\(attrs?[.modificationDate] ?? Date.distantPast)"
    }

    /// Трек для выбора музыки агентом: id и то, что известно о настроении.
    private static func musicData(_ track: MusicTrack) -> AgentJSONValue {
        var data: [String: AgentJSONValue] = ["id": .string(track.id)]
        if let mood = track.mood { data["mood"] = .string(mood) }
        if let energy = track.energy { data["energy"] = .number(Double(energy)) }
        if let bpm = track.bpm { data["bpm"] = .number(Double(bpm)) }
        return .object(data)
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

    static let maxJobWaitSeconds = 30.0

    /// `waitSeconds` > 0: не отвечать сразу, а подождать, пока у идущей задачи
    /// сменится статус или этап (но не дольше 30 секунд). Так агент тратит один
    /// вызов вместо серии опросов.
    func job(id: UUID, waitSeconds: Double = 0) async -> AgentResponse {
        do {
            var run = try await runs.reconcile(id: id)
            let deadline = Date().addingTimeInterval(min(Self.maxJobWaitSeconds, max(0, waitSeconds)))
            let started = (status: run.status, stage: run.stage)
            while run.status == .pending || run.status == .running, Date() < deadline {
                try await Task.sleep(for: .milliseconds(500))
                run = try await runs.reconcile(id: id)
                if run.status != started.status || run.stage != started.stage { break }
            }
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

    func inspect(
        projectID: UUID, around cuts: [Double] = [], offset: Int = 0, limit: Int = 200
    ) async -> AgentResponse {
        do {
            let project = try await store.load(id: projectID)
            let missing = Set(project.clips.map(\.sourcePath)).filter { !FileManager.default.fileExists(atPath: $0) }
            let start = min(max(0, offset), project.clips.count)
            let end = min(project.clips.count, start + min(500, max(1, limit)))
            var data: [String: AgentJSONValue] = [
                "projectId": .string(project.id.uuidString), "duration": .number(project.totalDuration),
                "clipCount": .number(Double(project.clips.count)),
                "timeline": .string(AgentWordCuts.fingerprint(project.clips)),
                "exportFingerprint": .string(ExportProvenance.fingerprint(for: project)),
                "dependencyFingerprint": .string(
                    await inputDependencyFingerprint(
                        sources: uniqueSources(project.clips), project: project)),
                "missingFiles": .array(missing.sorted().map { .string($0) }),
                "revision": .number(Double(await revisions.revision(of: project.id))),
                "clips": clipsData(project, offset: start, limit: end - start),
                "offset": .number(Double(start)),
                "nextOffset": end < project.clips.count ? .number(Double(end)) : .null,
                "cutChecks": .array(
                    cuts.prefix(50).map {
                        .object([
                            "time": .number($0), "from": .number(max(0, $0 - 1.5)), "to": .number($0 + 1.5),
                        ])
                    }),
                "shorts": Self.shortsData(project),
                "notes": await notes.read(project.id).map { .string($0) } ?? .null,
            ]
            // Обычный проект: размер кадра (для анимаций HyperFrames) и анимации на ленте.
            data.merge(await overlaysData(project)) { _, new in new }
            return .success(command: "inspect", data: data)
        } catch { return failure("inspect", error) }
    }

    /// External inputs are not stored inside Project. Keep their separate version
    /// so legacy export provenance remains compatible while pipeline caches are safe.
    func inputDependencyFingerprint(sources: [MediaReference], project: Project? = nil) async -> String {
        let transcripts = makeTranscriptStore()
        var documents = [store.glossaryURL]
        var media = sources.compactMap(\.resolvedURL)
        for source in sources {
            let cache = await transcripts.cacheURL(for: source)
            documents += [cache, TranscriptCorrections.url(forTranscript: cache)]
        }
        if let project {
            media += project.overlays.compactMap { $0.media.resolvedURL }
            if project.music.enabled {
                if let custom = project.music.customMedia?.resolvedURL {
                    media.append(custom)
                } else if let id = project.music.trackID, let track = MusicLibrary.track(id: id) {
                    media.append(track.url)
                }
            }
        }
        let versions =
            documents.map { url -> String in
                let hash = (try? Data(contentsOf: url)).map { SHA256.hash(data: $0).hex } ?? "missing"
                return "\(url.path)|\(hash)"
            }
            + media.map { url -> String in
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                return
                    "\(url.path)|\(attributes?[.size] ?? "missing")|\((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1)"
            }
        let subtitles = project?.export.burnSubtitles == true ? String(reflecting: ShortsSubtitleSettings.saved()) : ""
        return SHA256.hash(data: Data((versions.sorted().joined(separator: "\n") + subtitles).utf8)).hex
    }

    /// Оформление черновика шортса для агента; у обычного проекта — null.
    /// Наезды показаны во времени ленты: вырезанные части наезда не видны.
    static func shortsData(_ project: Project) -> AgentJSONValue {
        guard let shorts = project.shorts else { return .null }
        let starts = TimelineEditOps.starts(of: project.clips)
        let zooms: [AgentJSONValue] = shorts.zooms.compactMap { zoom in
            let spans = zip(project.clips, starts).compactMap { clip, start -> (Double, Double)? in
                guard clip.source.id == zoom.sourceID else { return nil }
                let from = max(zoom.sourceStart, clip.start)
                let to = min(zoom.sourceEnd, clip.end)
                return to > from ? (start + from - clip.start, start + to - clip.start) : nil
            }
            guard let first = spans.first, let last = spans.last else { return nil }
            return .object([
                "timelineStart": .number(rounded(first.0)), "timelineEnd": .number(rounded(last.1)),
                "scale": .number(zoom.scale),
            ])
        }
        return .object([
            "title": .string(shorts.title),
            "hook": shorts.hook.map { .string($0.text) } ?? .null,
            "layout": .string(shorts.resolvedLayout.rawValue),
            "subtitles": .bool(shorts.subtitles != nil),
            "zooms": .array(zooms),
            "music": project.music.enabled
                ? .object(["track": .string(project.music.trackID ?? ""), "volume": .number(project.music.volume)])
                : .null,
            "exportPath": shorts.exportPath.map { .string($0) } ?? .null,
        ])
    }

    func resource(uri: String, offset: Int? = nil, limit: Int? = nil) async throws -> String {
        guard uri.hasPrefix("montazhka://runs/"),
            let url = URL(string: uri), url.pathComponents.count >= 3,
            let id = UUID(uuidString: url.pathComponents[1])
        else { throw AgentServiceError.invalidInput("Неверный адрес ресурса.") }
        let run = try await runs.load(id: id)
        let name = url.lastPathComponent
        guard let path = run.artifacts[name], FileManager.default.fileExists(atPath: path) else {
            throw AgentServiceError.invalidInput("Ресурс \(name) не найден.")
        }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let requestedOffset = offset ?? query.firstValue(named: "offset").flatMap(Int.init) ?? 0
        let requestedLimit = limit ?? query.firstValue(named: "limit").flatMap(Int.init) ?? 32_000
        let file = URL(fileURLWithPath: path)
        let page: AgentResourcePage
        // Готовый ролик — видео, даже если агент сохранил его без расширения.
        let isVideoArtifact = name == "final" || name == "draft"
        if let media = AgentResourceReader.mediaType(of: file) ?? (isVideoArtifact ? .mpeg4Movie : nil) {
            page = AgentResourcePage(
                uri: uri, kind: "media", offset: 0, totalBytes: try AgentResourceReader.byteCount(of: file),
                mimeType: media.preferredMIMEType, path: path)
        } else {
            let text = try AgentResourceReader.textPage(
                at: file, offset: requestedOffset, limit: min(64_000, max(1, requestedLimit)))
            let nextURI =
                text.end < text.total
                ? "montazhka://runs/\(id.uuidString)/\(name)?offset=\(text.end)&limit=\(requestedLimit)" : nil
            page = AgentResourcePage(
                uri: uri, kind: "text", offset: text.start, totalBytes: text.total, content: text.content,
                nextUri: nextURI)
        }
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
        try await runs.claim(id: run.id)
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
