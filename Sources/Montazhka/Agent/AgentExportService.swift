import Foundation

extension AgentService {
    func export(
        projectID: UUID, outputPath: String?, quality: String,
        final: Bool, confirmFinal: Bool, overwrite: Bool,
        runMode: AgentRunMode = .standalone
    ) async -> AgentResponse {
        var activeRunID: UUID?
        do {
            if final && !confirmFinal { throw AgentServiceError.finalApprovalRequired }
            let project = try await store.load(id: projectID)
            guard let first = project.clips.first else { throw AgentServiceError.emptyProject }
            let destination = outputPath.map(URL.init(fileURLWithPath:)) ?? Self.defaultDraftURL(source: first.url)
            if FileManager.default.fileExists(atPath: destination.path), !overwrite {
                throw AgentServiceError.outputExists(destination.path)
            }
            let run = try await beginRun(
                mode: runMode, kind: .export, sourcePaths: project.clips.map(\.sourcePath),
                stage: "Экспорт", projectID: project.id)
            activeRunID = run.id
            let voice = VoiceEnhanceStore(cacheDir: store.enhancedAudioDir)
            let music = MusicEQStore(cacheDir: store.musicEQDir)
            let rendered = await MediaPipeline(voiceStore: voice, musicEQStore: music).render(
                MediaRenderRequest(project: project, mode: .export, readyEnhancedAudio: [:]))
            guard let exportQuality = ExportQuality(rawValue: quality) else {
                throw AgentServiceError.invalidInput("Неизвестное качество экспорта: \(quality)")
            }
            let input = ExportInput(composition: rendered.composition, audioMix: rendered.audioMix)
            let settings = try await Transcoder.settings(for: exportQuality, input: input)
            try await Transcoder.export(input: input, settings: settings, to: destination) { progress in
                Task { try? await self.runs.update(id: run.id) { $0.progress = max($0.progress, progress) } }
            }
            try await runs.update(id: run.id) {
                $0.status = .completed; $0.progress = 1; $0.stage = "Экспорт готов"
                $0.summary = destination.path; $0.artifacts[final ? "final" : "draft"] = destination.path
            }
            return .success(
                command: "export",
                data: [
                    "jobId": .string(run.id.uuidString), "status": .string("completed"),
                    "path": .string(destination.path), "final": .bool(final),
                ])
        } catch {
            if let activeRunID { await failRun(id: activeRunID, error: error) }
            return failure("export", error)
        }
    }

    private static func defaultDraftURL(source: URL) -> URL {
        let base = source.deletingPathExtension().lastPathComponent
        return source.deletingLastPathComponent().appendingPathComponent("\(base)-montazhka-draft.mp4")
    }
}
