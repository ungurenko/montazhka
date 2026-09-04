@preconcurrency import AVFoundation
import Foundation

extension AgentService {
    func edit(_ request: AgentEditRequest, runMode: AgentRunMode = .standalone) async -> AgentResponse {
        var activeRunID: UUID?
        do {
            let paths = request.sourcePaths.map { URL(fileURLWithPath: $0).standardized.path }
            for path in paths where !FileManager.default.fileExists(atPath: path) {
                throw AgentServiceError.missingFile(path)
            }
            if request.aiMode != .off,
                let refusal = await refusalIfModelNeedsDownload(
                    command: "edit_video", confirmed: request.confirmModelDownload)
            {
                return refusal
            }
            let run = try await beginRun(
                mode: runMode, kind: request.projectID == nil ? .editVideo : .editProject,
                sourcePaths: paths,
                stage: "Подготовка проекта")
            activeRunID = run.id
            var project = try await makeProject(request: request, paths: paths)
            if request.aiMode == .external {
                return try await prepareExternalEdit(project: project, runID: run.id)
            }
            if request.aiMode == .builtIn {
                project = try await applyingSmartEdit(to: project, runID: run.id)
            }
            if request.removePauses { project = await removePauses(from: project, profile: request.profile) }
            project = try applyingCuts(request.cuts, to: project)
            project.voiceEnhance.enabled = request.enhanceVoice
            try applyMusic(request.musicPath, to: &project)
            guard !project.clips.isEmpty else { throw AgentServiceError.emptyProject }
            try await store.save(project)
            let report = try await writeReport(runID: run.id, project: project, profile: request.profile)
            try await runs.update(id: run.id) {
                $0.status = .completed; $0.progress = 1; $0.stage = "Проект готов"
                $0.projectID = project.id; $0.summary = "Создана копия проекта с \(project.clips.count) клипами."
                $0.artifacts["report"] = report.path
            }
            return .success(
                command: "edit_video",
                data: [
                    "jobId": .string(run.id.uuidString), "projectId": .string(project.id.uuidString),
                    "status": .string("completed"), "report": .string("montazhka://runs/\(run.id.uuidString)/report"),
                ])
        } catch {
            if let activeRunID { await failRun(id: activeRunID, error: error) }
            return failure("edit_video", error)
        }
    }

    private func prepareExternalEdit(project: Project, runID: UUID) async throws -> AgentResponse {
        let transcriptStore = makeTranscriptStore()
        var seen = Set<UUID>()
        let sources = project.clips.compactMap { clip in
            seen.insert(clip.source.id).inserted ? clip.source : nil
        }
        var words: [TranscriptWord] = []
        for (index, source) in sources.enumerated() {
            let transcript = try await transcriptStore.ensure(source: source) { _ in
                try? await self.runs.update(id: runID) {
                    $0.stage = "Расшифровка \(index + 1) из \(sources.count)"
                    $0.progress = Double(index) / Double(max(1, sources.count))
                }
            }
            words.append(contentsOf: transcript)
        }
        guard !words.isEmpty else { throw SmartEditError.emptyTranscript }
        try await store.save(project)
        let directory = try await runs.artifactDirectory(id: runID)
        let transcriptURL = directory.appendingPathComponent("transcript.json")
        try JSONEncoder().encode(TranscriptDocument(words: words)).write(
            to: transcriptURL, options: .atomic)
        try await runs.update(id: runID) {
            $0.status = .waitingForApproval
            $0.progress = 1
            $0.stage = "Ожидаются точные резы"
            $0.projectID = project.id
            $0.summary = "Расшифровка готова. Передайте резы в montazhka_edit_project."
            $0.artifacts["transcript"] = transcriptURL.path
        }
        return .success(
            command: "edit_video",
            data: [
                "jobId": .string(runID.uuidString),
                "projectId": .string(project.id.uuidString),
                "status": .string(AgentRunStatus.waitingForApproval.rawValue),
                "transcript": .string("montazhka://runs/\(runID.uuidString)/transcript"),
            ])
    }

    private func applyingSmartEdit(to project: Project, runID: UUID) async throws -> Project {
        let transcriptStore = makeTranscriptStore()
        let configuration = try await AgentAIConfigurationResolver.resolve(
            reasoningKey: EditorController.smartEditReasoningKey)
        let service = SmartEditService(
            transcriptStore: transcriptStore,
            ai: UnifiedAIClient(openRouter: OpenRouterClient()),
            waveforms: waveforms)
        let analysis = try await service.analyze(
            clips: project.clips, projectThresholdDB: project.detection.thresholdDB,
            configuration: configuration,
            status: { status in
                try? await self.runs.update(id: runID) { $0.stage = Self.stage(status) }
            })
        let ranges = SmartEditRanges.merged(
            analysis.candidates.filter(\.enabled).map {
                (start: $0.timelineStart, end: $0.timelineEnd)
            })
        var result = project
        for range in ranges.reversed() {
            result.clips = TimelineOps.removingRange(
                clips: result.clips, start: range.start, end: range.end)
        }
        return result
    }

    private func applyingCuts(_ cuts: [AgentSourceCut], to project: Project) throws -> Project {
        guard !cuts.isEmpty else { return project }
        let projectSources = Dictionary(grouping: Set(project.clips.map(\.sourcePath))) {
            URL(fileURLWithPath: $0).standardized.path
        }
        let normalizedCuts = try cuts.map { cut -> AgentSourceCut in
            let path = URL(fileURLWithPath: cut.sourcePath).standardized.path
            guard projectSources[path] != nil else {
                throw AgentServiceError.invalidInput("Источник реза не входит в проект: \(path)")
            }
            guard cut.start >= 0, cut.end > cut.start else {
                throw AgentServiceError.invalidInput("Неверный диапазон реза: \(cut.start)–\(cut.end)")
            }
            return AgentSourceCut(sourcePath: path, start: cut.start, end: cut.end)
        }
        var result = project
        for group in Dictionary(grouping: normalizedCuts, by: \AgentSourceCut.sourcePath) {
            for sourcePath in projectSources[group.key] ?? [] {
                result.clips = TimelineOps.removingSourceRanges(
                    clips: result.clips, sourcePath: sourcePath,
                    ranges: group.value.map { (start: $0.start, end: $0.end) })
            }
        }
        return result
    }

    private func applyMusic(_ musicPath: String?, to project: inout Project) throws {
        guard let musicPath else {
            project.music.enabled = false
            return
        }
        let path = URL(fileURLWithPath: musicPath).standardized.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw AgentServiceError.missingFile(path)
        }
        project.music = MusicSettings(
            enabled: true, customMedia: MediaReference(path: path), volume: 18)
    }

    private func makeProject(request: AgentEditRequest, paths: [String]) async throws -> Project {
        if let id = request.projectID {
            let lock = try AgentProjectLock(projectID: id, directory: store.projectsDir)
            defer { withExtendedLifetime(lock) {} }
            var source = try await store.load(id: id)
            source.id = UUID(); source.name = request.name ?? "\(source.name) — AI-черновик"
            source.createdAt = Date(); source.updatedAt = Date()
            return source
        }
        guard !paths.isEmpty else {
            throw AgentServiceError.invalidInput("Нужен projectId или хотя бы один sourcePath.")
        }
        var clips: [Clip] = []
        for path in paths {
            let asset = AVURLAsset(url: URL(fileURLWithPath: path))
            guard let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 0 else {
                throw AgentServiceError.invalidInput("Не удалось определить длительность: \(path)")
            }
            clips.append(Clip(sourcePath: path, start: 0, end: duration))
        }
        return Project(name: request.name ?? ProjectStore.defaultProjectName(), clips: clips)
    }

    private func removePauses(from project: Project, profile: AgentEditProfile) async -> Project {
        var result = project
        result.detection =
            profile == .dynamic
            ? DetectionSettings(thresholdDB: -38, minPauseDuration: 0.55, paddingMS: 110)
            : DetectionSettings()
        for source in Set(result.clips.map(\.sourcePath)) { _ = await waveforms.ensure(path: source) }
        let pauses = SilenceDetector.findPauses(
            clips: result.clips, peaksFor: { self.waveforms.peaks(for: $0) }, settings: result.detection)
        for pause in pauses.sorted(by: { $0.start > $1.start }) {
            result.clips = TimelineOps.removingRange(clips: result.clips, start: pause.start, end: pause.end)
        }
        return result
    }

    private func writeReport(runID: UUID, project: Project, profile: AgentEditProfile) async throws -> URL {
        let directory = try await runs.artifactDirectory(id: runID)
        let url = directory.appendingPathComponent("report.md")
        let text = """
            # Отчёт «Монтажки»

            - Проект: \(project.name)
            - Профиль: \(profile.rawValue)
            - Кусочков: \(project.clips.count)
            - Длительность: \(String(format: "%.2f", project.totalDuration)) сек.
            - Голос: \(project.voiceEnhance.enabled ? "улучшение включено" : "без обработки")
            - Музыка: \(project.music.enabled ? "включена" : "выключена")

            Исходные видео не изменялись. Перед финальным экспортом проверьте черновик и склейки.
            """
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }

    private static func stage(_ status: SmartEditStatus) -> String {
        switch status {
        case .idle: "Ожидание"
        case .preparingModel: "Подготовка модели"
        case .transcribing: "Расшифровка"
        case .proposing: "Поиск речевых исправлений"
        case .reviewing: "Проверка исправлений"
        case .preparingCuts: "Подготовка резов"
        case .ready: "Умный монтаж готов"
        case .failed(let error): error.message
        }
    }
}
