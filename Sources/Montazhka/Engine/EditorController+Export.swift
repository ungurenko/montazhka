@preconcurrency import AVFoundation
import Foundation

/// Подготовка экспорта окна: обычный проект и черновик шортса.
extension EditorController {
    /// Композиция для экспорта. Если улучшение включено — дожидается обработки всех
    /// исходников; при неудаче отдаёт оригинальный звук и текст предупреждения.
    /// `videoComposition` — анимации и вшитые субтитры; nil — кадр как есть.
    func compositionForExport(
        _ snapshot: Project, speechRanges: [TimelineRange]?, subtitleLayer: ProjectSubtitleLayer? = nil
    ) async -> (
        composition: AVComposition,
        audioMix: AVAudioMix?,
        videoComposition: AVVideoComposition?,
        audioWarning: String?
    ) {
        let result = await renderComposition(
            snapshot, mode: .export, speechRanges: speechRanges, subtitleLayer: subtitleLayer)
        let warning =
            result.warnings.isEmpty
            ? nil
            : result.warnings.map(\.message).joined(separator: "\n")
        return (result.composition, result.audioMix, result.videoPlan?.exportComposition, warning)
    }

    /// Обычный проект: слова ленты дают .srt, вшитые субтитры (если включены)
    /// и приглушение музыки под голосом; анимации ложатся поверх кадра.
    /// Нет готовой расшифровки — речь распознаётся сейчас, если модель уже скачана.
    func prepareExport(step: @escaping @Sendable (ExportPreparationStep) -> Void) async throws -> PreparedExport {
        if project.shorts != nil { return try await prepareShortsExport() }
        // Та версия проекта, из которой соберётся файл, — до ожидания расшифровки и сборки.
        let exported = project
        let speech = try await ExportSpeech.load(
            clips: exported.clips, store: transcriptStore, glossaryURL: repository.directories.glossary,
            transcribing: { step(.transcribing($0)) })
        step(.assembling)
        let burned = exported.export.burnSubtitles ? ProjectSubtitleLayer.saved(cues: speech.horizontalCues) : nil
        let result = await compositionForExport(
            exported, speechRanges: speech.speechRanges, subtitleLayer: burned)
        // Речь распознана сейчас (или расшифровка сменилась) — предпросмотр собирается
        // заново: в нём появляются субтитры и музыка стихает под голосом.
        if exported.clips == project.clips, (speech.horizontalCues ?? []) != previewSubtitleCues {
            rebuildAndSeek(to: currentTime)
        }
        return PreparedExport(
            composition: result.composition, audioMix: result.audioMix, warning: result.audioWarning,
            videoComposition: result.videoComposition,
            subtitleCues: speech.horizontalCues, subtitlesSkippedReason: speech.skippedReason,
            normalizeLoudness: exported.export.normalizeLoudness,
            projectFingerprint: ExportProvenance.fingerprint(for: exported), sizing: .quality)
    }

    /// Слова ленты только из готовой расшифровки — без распознавания.
    func cachedSpeech(for clips: [Clip]) async -> ExportSpeech {
        let words = try? await transcriptStore.correctedCachedWords(
            for: uniqueMediaSources(in: clips), glossaryURL: repository.directories.glossary)
        return ExportSpeech(clips: clips, words: words)
    }

    /// Черновик шортса выгружается так же, как у агента: вертикально, с лицом,
    /// наездами, хуком и субтитрами. .srt — те же фразы шортса.
    func prepareShortsExport() async throws -> PreparedExport {
        let directories = repository.directories
        let sources = Array(
            Dictionary(project.clips.map { ($0.source.id, $0.source) }, uniquingKeysWith: { a, _ in a }).values)
        let words = try await transcriptStore.correctedCachedWords(for: sources, glossaryURL: directories.glossary)
        let exported = project
        let plan = try await ShortsRenderer.plan(
            project: exported, words: words ?? [], faces: FaceTrackStore(cacheDir: directories.faceTracks),
            quality: .high, voiceStore: VoiceEnhanceStore(cacheDir: directories.enhancedAudio),
            musicEQStore: MusicEQStore(cacheDir: directories.musicEQ))
        return PreparedExport(
            composition: plan.composition, audioMix: plan.audioMix,
            warning: plan.warnings.isEmpty ? nil : plan.warnings.map(\.message).joined(separator: "\n"),
            videoComposition: plan.exportComposition,
            subtitleCues: words == nil ? nil : plan.subtitleFileCues,
            subtitlesSkippedReason: words == nil ? ExportSpeech.noTranscriptReason : nil,
            normalizeLoudness: exported.export.normalizeLoudness,
            projectFingerprint: ExportProvenance.fingerprint(for: exported))
    }
}
