@preconcurrency import AVFoundation
import Foundation

extension AgentService {
    /// Что проверить после финального файла.
    static let finalExportNextSteps = [
        "montazhka_check projectId filePath — проверьте склейки готового файла",
        "Критик: прочитайте ресурс montazhka://critic и запустите проверку отдельным субагентом",
    ]

    /// `normalizeLoudness`, `burnSubtitles`: nil — как в `project.export`.
    /// .srt ложится рядом всегда; `burnSubtitles` ещё и впечатывает фразы в кадр
    /// обычного проекта (у черновика шортса свои субтитры).
    func export(
        projectID: UUID, outputPath: String?, quality: String,
        final: Bool, confirmFinal: Bool, overwrite: Bool,
        normalizeLoudness: Bool? = nil, burnSubtitles: Bool? = nil,
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
            let stage: @Sendable (FinalExportStage) -> Void = { stage in
                Task { try? await self.runs.update(id: run.id) { $0.stage = stage.caption } }
            }
            let normalize = normalizeLoudness ?? project.export.normalizeLoudness
            let (job, renderWarnings) = try await exportJob(
                project, quality: exportQuality, normalize: normalize,
                burnSubtitles: burnSubtitles ?? project.export.burnSubtitles, runID: run.id)
            let report = try await FinalExport.run(job, to: destination, progress: progress, stage: stage)
            let actual = try await AVURLAsset(url: destination).load(.duration).seconds
            let matches = abs(actual - project.totalDuration) <= 0.25
            try await runs.update(id: run.id) {
                $0.status = .completed; $0.progress = 1; $0.stage = "Экспорт готов"
                $0.summary =
                    "\(destination.path) · длительность \(String(format: "%.2f", actual)) из "
                    + "\(String(format: "%.2f", project.totalDuration)) с\(matches ? "" : " — НЕ СОВПАДАЕТ")"
                    + " · \(Self.loudnessSummary(report))"
                $0.artifacts[final ? "final" : "draft"] = destination.path
                if let subtitles = report.subtitlesURL { $0.artifacts["subtitles"] = subtitles.path }
            }
            var data: [String: AgentJSONValue] = [
                "jobId": .string(run.id.uuidString), "status": .string("completed"),
                "path": .string(destination.path), "final": .bool(final),
                "durationCheck": .object([
                    "fileSeconds": .number(Self.rounded(actual)),
                    "projectSeconds": .number(Self.rounded(project.totalDuration)),
                    "matches": .bool(matches),
                ]),
                "loudness": Self.loudnessPayload(report),
                "subtitlesPath": report.subtitlesURL.map { .string($0.path) } ?? .null,
                "warnings": .array((renderWarnings + report.warnings).map { .string($0) }),
            ]
            if report.subtitlesURL == nil, let reason = report.subtitlesSkippedReason {
                data["subtitlesSkippedReason"] = .string(reason)
            }
            if final { data["nextSteps"] = .array(Self.finalExportNextSteps.map { .string($0) }) }
            return .success(command: "export", data: data)
        } catch {
            if let activeRunID { await failRun(id: activeRunID, error: error) }
            return failure("export", error)
        }
    }

    /// Задание записи и предупреждения сборки. Шортс — по плану черновика;
    /// обычный проект — слова ленты для .srt, вшитых субтитров и приглушения
    /// музыки, анимации поверх кадра. Расшифровка здесь (в фоновом процессе)
    /// запускается, если модель уже скачана.
    private func exportJob(
        _ project: Project, quality: ExportQuality, normalize: Bool, burnSubtitles: Bool, runID: UUID
    ) async throws -> (FinalExportJob, [String]) {
        // Отпечаток сохранённой версии: разовые normalize/burnSubtitles его не меняют.
        let fingerprint = ExportProvenance.fingerprint(for: project)
        if project.shorts != nil {
            let words = (try? await cachedTranscriptWords(for: project)) ?? nil
            let plan = try await shortsPlan(project, words: words, quality: quality)
            let job = plan.exportJob(
                quality: quality, normalizeLoudness: normalize, projectFingerprint: fingerprint,
                subtitlesSkippedReason: words == nil ? ExportSpeech.noTranscriptReason : nil)
            return (job, plan.warnings.map(\.message))
        }
        let speech = try await ExportSpeech.load(
            clips: project.clips, store: makeTranscriptStore(), glossaryURL: store.glossaryURL,
            transcribing: { fraction in
                let stage = fraction.map { "Распознаю речь: \(Int($0 * 100)) %" } ?? "Распознаю речь"
                Task { try? await self.runs.update(id: runID) { $0.stage = stage } }
            })
        let voice = VoiceEnhanceStore(cacheDir: store.enhancedAudioDir)
        let music = MusicEQStore(cacheDir: store.musicEQDir)
        let rendered = await MediaPipeline(voiceStore: voice, musicEQStore: music).render(
            MediaRenderRequest(
                project: project, mode: .export, readyEnhancedAudio: [:], speechRanges: speech.speechRanges,
                subtitleLayer: burnSubtitles ? ProjectSubtitleLayer.saved(cues: speech.horizontalCues) : nil))
        let job = FinalExportJob(
            input: ExportInput(
                composition: rendered.composition, audioMix: rendered.audioMix,
                videoComposition: rendered.videoPlan?.exportComposition),
            quality: quality, sizing: .quality(quality), subtitleCues: speech.horizontalCues,
            subtitlesSkippedReason: speech.skippedReason, normalizeLoudness: normalize,
            projectFingerprint: fingerprint)
        return (job, rendered.warnings.map(\.message))
    }

    /// Громкость готового файла для ответа агенту; неизвестное — null.
    static func loudnessPayload(_ report: FinalExportReport) -> AgentJSONValue {
        let loudness = report.loudness
        return .object([
            "integratedLUFS": loudness?.integratedLUFS.map { .number(rounded($0)) } ?? .null,
            "truePeakDBTP": loudness.map { .number(rounded($0.truePeakDBTP)) } ?? .null,
            "loudnessRangeLU": loudness?.loudnessRangeLU.map { .number(rounded($0)) } ?? .null,
            "normalized": .bool(report.normalized),
            "gainDB": .number(rounded(report.gainDB)),
            "targetLUFS": .number(LoudnessTarget().integrated),
            "targetMet": report.targetMet.map { .bool($0) } ?? .null,
        ])
    }

    private static func loudnessSummary(_ report: FinalExportReport) -> String {
        guard let loudness = report.loudness, let integrated = loudness.integratedLUFS else {
            return "громкость не замерена"
        }
        let verdict = report.targetMet.map { $0 ? " — по стандарту" : " — НЕ по стандарту" } ?? ""
        return "громкость \(String(format: "%.1f", integrated)) LUFS, пик "
            + "\(String(format: "%.1f", loudness.truePeakDBTP)) dBTP\(verdict)"
    }

    /// План черновика шортса со словами из кэша расшифровки (если она есть).
    func shortsPlan(_ project: Project, quality: ExportQuality) async throws -> ShortsRenderer.Plan {
        try await shortsPlan(project, words: (try? await cachedTranscriptWords(for: project)) ?? nil, quality: quality)
    }

    /// План черновика шортса по уже прочитанным словам; nil — расшифровки нет.
    func shortsPlan(
        _ project: Project, words: [TranscriptWord]?, quality: ExportQuality
    ) async throws -> ShortsRenderer.Plan {
        try await ShortsRenderer.plan(
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
