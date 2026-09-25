@preconcurrency import AVFoundation
import Foundation

/// `montazhka_make_shorts`: моменты выбрал агент, программа собирает из них
/// черновики-проекты и выгружает MP4. Встроенный платный отбор здесь не
/// вызывается никогда.
struct AgentShortsRequest: Codable, Sendable {
    var projectID: UUID
    /// Отпечаток ленты из `montazhka_transcript`: номера слов верны только для него.
    var timeline: String
    var shorts: [ShortsDraftFactory.Spec]
    var removeFillers: Bool?
    var trimPauses: Bool?
    var quality: String?

    private enum CodingKeys: String, CodingKey {
        case projectID = "projectId", timeline, shorts, removeFillers, trimPauses, quality
    }
}

extension AgentService {
    func makeShorts(_ request: AgentShortsRequest, runMode: AgentRunMode = .standalone) async -> AgentResponse {
        guard !request.shorts.isEmpty else {
            return .failure(
                command: "make_shorts", code: "INVALID_REQUEST",
                message: "Не переданы ролики: моменты для шортсов выбираете вы.",
                recovery: "Прочитайте montazhka_transcript проекта, выберите моменты, покажите их пользователю "
                    + "и передайте shorts: [{title, hook, pieces: [{from, to}]}] с timeline из расшифровки.")
        }
        var activeRunID: UUID?
        do {
            guard let quality = ExportQuality(rawValue: request.quality ?? "high") else {
                throw AgentServiceError.invalidInput("Неизвестное качество экспорта: \(request.quality ?? "")")
            }
            let project = try await store.load(id: request.projectID)
            guard !project.clips.isEmpty else { throw AgentServiceError.emptyProject }
            guard request.timeline == AgentWordCuts.fingerprint(project.clips) else {
                throw AgentServiceError.invalidInput(
                    "Лента проекта изменилась после чтения расшифровки, номера слов устарели. "
                        + "Вызовите montazhka_transcript заново и возьмите новый timeline.")
            }
            let words = try await cachedTranscriptWords(for: project) ?? []
            let map = TranscriptTimelineMapper.make(clips: project.clips, transcripts: words).words
            var peaks: [String: [Float]] = [:]
            var durations: [UUID: Double] = [:]
            for clip in project.clips where durations[clip.source.id] == nil {
                peaks[clip.sourcePath] = await waveforms.ensure(path: clip.sourcePath)
                durations[clip.source.id] = try await AVURLAsset(url: clip.url).load(.duration).seconds
            }
            let run = try await beginRun(
                mode: runMode, kind: .makeShorts, sourcePaths: project.clips.map(\.sourcePath),
                stage: "Сборка черновиков", projectID: project.id)
            activeRunID = run.id

            let faces = FaceTrackStore(cacheDir: store.faceTracksDir)
            var results: [AgentJSONValue] = []
            for (index, spec) in request.shorts.enumerated() {
                try await runs.update(id: run.id) {
                    $0.stage = "Шортс \(index + 1) из \(request.shorts.count): \(spec.title)"
                    $0.progress = Double(index) / Double(request.shorts.count)
                }
                let draft = try await makeDraft(
                    spec, index: index, from: project, map: map, words: words, peaks: peaks, durations: durations,
                    request: request, faces: faces)
                let plan = try await shortsPlan(draft, quality: quality)
                let output = URL(fileURLWithPath: draft.shorts?.exportPath ?? "")
                try await ShortsRenderer.export(plan, quality: quality, to: output) { _ in }
                results.append(
                    .object([
                        "projectId": .string(draft.id.uuidString), "title": .string(spec.title),
                        "output": .string(output.path), "duration": .number(Self.rounded(draft.totalDuration)),
                        "layout": .string(draft.shorts?.resolvedLayout.rawValue ?? ""),
                        "music": draft.music.enabled ? .string(draft.music.trackID ?? "") : .null,
                        "warnings": .array(Self.draftWarnings(draft, plan: plan).map { .string($0) }),
                    ]))
            }
            try await runs.update(id: run.id) {
                $0.status = .completed; $0.progress = 1; $0.stage = "Шортсы готовы"
                $0.summary = "Создано черновиков: \(results.count)."
            }
            return .success(
                command: "make_shorts",
                data: [
                    "jobId": .string(run.id.uuidString), "status": .string("completed"), "shorts": .array(results),
                    "next": .string(
                        "Проверьте каждый черновик: montazhka_frames projectId (вертикальный кадр с хуком), "
                            + "aroundCuts, montazhka_audio. Правки — apply_edits, затем montazhka_export."),
                ])
        } catch {
            if let activeRunID { await failRun(id: activeRunID, error: error) }
            return failure("make_shorts", error)
        }
    }

    /// Один черновик: лента из кусков, оформление, музыка; сохраняется в проекты.
    private func makeDraft(
        _ spec: ShortsDraftFactory.Spec, index: Int, from project: Project, map: [MappedTranscriptWord],
        words: [TranscriptWord], peaks: [String: [Float]], durations: [UUID: Double],
        request: AgentShortsRequest, faces: FaceTrackStore
    ) async throws -> Project {
        let clips = try ShortsDraftFactory.clips(
            for: spec.pieces, map: map, clips: project.clips, peaksFor: { peaks[$0] },
            sourceDuration: { durations[$0] ?? .infinity }, thresholdDB: project.detection.thresholdDB,
            trimPauses: request.trimPauses ?? true, removeFillers: request.removeFillers ?? true)
        let hook = spec.hook.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : ShortsHook(text: $0) }
        let total = clips.reduce(0) { $0 + $1.duration }
        let draftMap = TranscriptTimelineMapper.make(clips: clips, transcripts: words).words
        let zooms =
            try spec.zooms.map { try ShortsDraftFactory.zooms($0, map: map) }
            ?? ShortsDraftFactory.autoZooms(map: draftMap, total: total, notBefore: hook?.duration ?? 0)
        let layout = spec.layout ?? .auto
        let resolved = layout == .auto ? try await suggestedLayout(clips, faces: faces) : layout
        let saved = ShortsSubtitleSettings.saved()

        let source = project.clips[0].url
        let folder = source.deletingLastPathComponent()
            .appendingPathComponent("\(source.deletingPathExtension().lastPathComponent)-shorts", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let output = ShortsExporter.fileURL(
            in: folder, sourceName: source.deletingPathExtension().lastPathComponent, index: index, title: spec.title)

        var draft = Project(name: "Шортс: \(spec.title)", clips: clips)
        draft.voiceEnhance.enabled = true
        draft.music = ShortsDraftFactory.music(track: spec.music, mood: spec.mood, variant: index)
        draft.shorts = ShortsPresentation(
            title: spec.title, reason: "", layout: layout, resolvedLayout: resolved, hook: hook,
            subtitles: spec.subtitles == true
                ? ShortsDraftSubtitles(appearance: saved.appearance, highlight: saved.highlightActiveWord) : nil,
            zooms: zooms, exportPath: output.path)
        try await store.save(draft)
        return draft
    }

    private func suggestedLayout(_ clips: [Clip], faces: FaceTrackStore) async throws -> ShortsDraftLayout {
        var samples: [FaceSample] = []
        for (_, group) in Dictionary(grouping: clips, by: \.source.id) {
            guard let url = group.first?.url else { continue }
            samples += try await faces.samples(for: url, ranges: group.map { $0.start...$0.end })
        }
        return FaceLayoutAdvisor.suggest(samples)
    }

    private static func draftWarnings(_ draft: Project, plan: ShortsRenderer.Plan) -> [String] {
        var warnings = plan.warnings.map(\.message)
        if draft.totalDuration < ShortsLimits.discardBelow || draft.totalDuration > ShortsLimits.maxDuration {
            warnings.append(
                "Длительность \(String(format: "%.1f", draft.totalDuration)) с — вне 12–60 с для Reels и Shorts.")
        }
        if draft.shorts?.resolvedLayout == .split,
            plan.frameComposition.instructions.first.map({
                ($0 as? AVVideoCompositionInstruction)?.layerInstructions.count
            }) == 1
        {
            warnings.append("Лицо для раскладки «экран + лицо» не найдено — показан обычный кадр по лицу.")
        }
        return warnings
    }
}
