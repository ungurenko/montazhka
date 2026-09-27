@preconcurrency import AVFoundation
import Foundation

/// Подготовка экспорта окна: обычный проект и черновик шортса.
extension EditorController {
    /// Композиция для экспорта. Если улучшение включено — дожидается обработки всех
    /// исходников; при неудаче отдаёт оригинальный звук и текст предупреждения.
    func compositionForExport() async -> (
        composition: AVComposition,
        audioMix: AVAudioMix?,
        audioWarning: String?
    ) {
        let result = await renderComposition(mode: .export)
        let warning =
            result.warnings.isEmpty
            ? nil
            : result.warnings.map(\.message).joined(separator: "\n")
        return (result.composition, result.audioMix, warning)
    }

    func prepareExport() async throws -> PreparedExport {
        if project.shorts != nil { return try await prepareShortsExport() }
        // Та версия проекта, из которой соберётся файл, — до ожидания сборки.
        let exported = project
        let result = await compositionForExport()
        return PreparedExport(
            composition: result.composition, audioMix: result.audioMix, warning: result.audioWarning,
            normalizeLoudness: exported.export.normalizeLoudness,
            timelineFingerprint: AgentWordCuts.fingerprint(exported.clips), sizing: .quality)
    }

    /// Черновик шортса выгружается так же, как у агента: вертикально, с лицом,
    /// наездами, хуком и субтитрами.
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
            normalizeLoudness: exported.export.normalizeLoudness,
            timelineFingerprint: AgentWordCuts.fingerprint(exported.clips))
    }
}
