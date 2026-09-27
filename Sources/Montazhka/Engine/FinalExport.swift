@preconcurrency import AVFoundation
import Foundation

/// Откуда берётся размер кадра готового файла.
enum ExportSizing: Sendable {
    /// Размер кадра — `renderSize` видеокомпозиции (черновик шортса).
    case composition
    /// Размер кадра — качество, применённое к кадру самой склейки.
    case quality(ExportQuality)
    /// Готовые размер и битрейты: старое окно шортсов считает их само.
    case settings(Transcoder.Settings)
}

/// Всё, что нужно для записи готового файла из любого входа экспорта.
/// @unchecked Sendable: композиции внутри `input` после сборки только читают.
struct FinalExportJob: @unchecked Sendable {
    var input: ExportInput
    var quality: ExportQuality
    var sizing: ExportSizing
    /// nil — файла субтитров нет.
    var subtitleCues: [ShortsSubtitleCue]?
    /// Почему реплик нет: нет расшифровки, нет модели, нет речи.
    var subtitlesSkippedReason: String?
    var normalizeLoudness: Bool
    /// Из какой ленты собран файл: `AgentWordCuts.fingerprint(project.clips)`.
    var timelineFingerprint: String?
}

/// Что стало со звуком и субтитрами готового файла.
struct FinalExportReport: Equatable, Sendable {
    var loudness: LoudnessMeasurement?
    var normalized: Bool
    var gainDB: Double
    var targetMet: Bool?
    var subtitlesURL: URL?
    var subtitlesSkippedReason: String?
    var warnings: [String]
}

/// Единый завершающий шаг всех входов экспорта: окно, `montazhka_export`,
/// `make_shorts` и старое окно шортсов.
enum FinalExport {
    static func run(
        _ job: FinalExportJob, to url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> FinalExportReport {
        try await writeVideo(job, to: url, progress: progress)
        return FinalExportReport(
            loudness: nil, normalized: false, gainDB: 0, targetMet: nil, subtitlesURL: nil,
            subtitlesSkippedReason: job.subtitlesSkippedReason, warnings: [])
    }

    private static func writeVideo(
        _ job: FinalExportJob, to url: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let input = job.input
        let quality: ExportQuality
        switch job.sizing {
        case .settings(let settings):
            try await Transcoder.exportWithOfflineComposition(
                input: input, settings: settings, to: url, progress: progress)
            return
        case .composition where input.videoComposition != nil:
            try await Transcoder.export(composed: input, quality: job.quality, to: url, progress: progress)
            return
        case .composition:
            // Без своей композиции размер кадра задаёт качество.
            quality = job.quality
        case .quality(let sized):
            quality = sized
        }
        // Размер считается по кадру самой склейки, без своей видеокомпозиции.
        let base = ExportInput(composition: input.composition, audioMix: input.audioMix)
        let settings = try await Transcoder.settings(for: quality, input: base)
        if input.videoComposition == nil {
            try await Transcoder.export(input: input, settings: settings, to: url, progress: progress)
        } else {
            try await Transcoder.exportWithOfflineComposition(
                input: input, settings: settings, to: url, progress: progress)
        }
    }
}
