@preconcurrency import AVFoundation
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
            let draftPath = project.shorts?.exportPath.map(URL.init(fileURLWithPath:))
            let destination =
                outputPath.map(URL.init(fileURLWithPath:)) ?? draftPath
                ?? Self.defaultOutputURL(source: first.url, final: final)
            // Файл черновика шортса перевыгружается после каждой правки — это не чужой файл.
            let overwrite = overwrite || destination.standardized == draftPath?.standardized
            let sources = Set(project.clips.map { URL(fileURLWithPath: $0.sourcePath).resolvingSymlinksInPath().path })
            if sources.contains(destination.resolvingSymlinksInPath().path) {
                throw AgentServiceError.invalidInput("Нельзя сохранять результат поверх исходника: \(destination.path)")
            }
            if FileManager.default.fileExists(atPath: destination.path), !overwrite {
                throw AgentServiceError.outputExists(destination.path)
            }
            let run = try await beginRun(
                mode: runMode, kind: .export, sourcePaths: project.clips.map(\.sourcePath),
                stage: "Экспорт", projectID: project.id)
            activeRunID = run.id
            guard let exportQuality = ExportQuality(rawValue: quality) else {
                throw AgentServiceError.invalidInput("Неизвестное качество экспорта: \(quality)")
            }
            let progress: @Sendable (Double) -> Void = { progress in
                Task { try? await self.runs.update(id: run.id) { $0.progress = max($0.progress, progress) } }
            }
            if project.shorts != nil {
                let plan = try await shortsPlan(project, quality: exportQuality)
                try await ShortsRenderer.export(plan, quality: exportQuality, to: destination, progress: progress)
            } else {
                let voice = VoiceEnhanceStore(cacheDir: store.enhancedAudioDir)
                let music = MusicEQStore(cacheDir: store.musicEQDir)
                let rendered = await MediaPipeline(voiceStore: voice, musicEQStore: music).render(
                    MediaRenderRequest(project: project, mode: .export, readyEnhancedAudio: [:]))
                let input = ExportInput(composition: rendered.composition, audioMix: rendered.audioMix)
                let settings = try await Transcoder.settings(for: exportQuality, input: input)
                try await Transcoder.export(input: input, settings: settings, to: destination, progress: progress)
            }
            let actual = try await AVURLAsset(url: destination).load(.duration).seconds
            let matches = abs(actual - project.totalDuration) <= 0.25
            try await runs.update(id: run.id) {
                $0.status = .completed; $0.progress = 1; $0.stage = "Экспорт готов"
                $0.summary =
                    "\(destination.path) · длительность \(String(format: "%.2f", actual)) из "
                    + "\(String(format: "%.2f", project.totalDuration)) с\(matches ? "" : " — НЕ СОВПАДАЕТ")"
                $0.artifacts[final ? "final" : "draft"] = destination.path
            }
            return .success(
                command: "export",
                data: [
                    "jobId": .string(run.id.uuidString), "status": .string("completed"),
                    "path": .string(destination.path), "final": .bool(final),
                    "durationCheck": .object([
                        "fileSeconds": .number(Self.rounded(actual)),
                        "projectSeconds": .number(Self.rounded(project.totalDuration)),
                        "matches": .bool(matches),
                    ]),
                ])
        } catch {
            if let activeRunID { await failRun(id: activeRunID, error: error) }
            return failure("export", error)
        }
    }

    /// План черновика шортса со словами из кэша расшифровки (если она есть).
    func shortsPlan(_ project: Project, quality: ExportQuality) async throws -> ShortsRenderer.Plan {
        let words = (try? await cachedTranscriptWords(for: project)) ?? nil
        return try await ShortsRenderer.plan(
            project: project, words: words ?? [], faces: FaceTrackStore(cacheDir: store.faceTracksDir),
            quality: quality, voiceStore: VoiceEnhanceStore(cacheDir: store.enhancedAudioDir),
            musicEQStore: MusicEQStore(cacheDir: store.musicEQDir))
    }

    private static func defaultOutputURL(source: URL, final: Bool) -> URL {
        let base = source.deletingPathExtension().lastPathComponent
        let suffix = final ? "montazhka" : "montazhka-draft"
        return source.deletingLastPathComponent().appendingPathComponent("\(base)-\(suffix).mp4")
    }
}
