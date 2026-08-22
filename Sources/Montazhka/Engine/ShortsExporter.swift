import AVFoundation
import Foundation

/// Экспорт одного ролика: композиция диапазона исходника, опциональный
/// кроп 9:16 по центру и перекодирование с выбранным качеством.
enum ShortsExporter {
    static func export(
        candidate: ShortCandidate,
        sourceURL: URL,
        displaySize: CGSize,
        quality: ExportQuality,
        cropVertical: Bool,
        subtitleMode: ShortsSubtitleMode = .off,
        to url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let clip = Clip(sourceURL: sourceURL, start: candidate.start, end: candidate.end)
        let built = await CompositionBuilder.build(clips: [clip])

        let plan = await ShortsVideoCompositionBuilder.make(
            asset: built.composition,
            displaySize: displaySize,
            cropVertical: cropVertical,
            subtitleMode: subtitleMode,
            subtitleTimeline: ShortsSubtitleTimeline(
                sourceStart: candidate.start,
                sourceEnd: candidate.end,
                relativeTo: candidate.start,
                duration: candidate.duration))
        let dimensions =
            plan.croppedRenderSize
            ?? quality.targetDimensions(forDisplaySize: displaySize)
        let settings = Transcoder.Settings(
            dimensions: dimensions,
            videoBitrate: quality.videoBitrate(forDimensions: dimensions),
            audioBitrate: quality.audioBitrate)
        try await Transcoder.exportWithOfflineComposition(
            input: ExportInput(
                composition: built.composition,
                audioMix: built.audioMix,
                videoComposition: plan.videoComposition),
            settings: settings,
            to: url,
            progress: progress)
    }

    /// Собирает композицию для плеера. Для превью сохраняется шкала исходника,
    /// поэтому boundary observer продолжает останавливать ролик на его конце,
    /// а субтитры показываются только внутри выбранного диапазона.
    static func previewComposition(
        for asset: AVAsset,
        displaySize: CGSize,
        cropVertical: Bool
    ) async -> AVMutableVideoComposition? {
        let plan = await ShortsVideoCompositionBuilder.make(
            asset: asset,
            displaySize: displaySize,
            cropVertical: cropVertical,
            subtitleMode: .off,
            subtitleTimeline: .empty)
        return plan.videoComposition
    }

    /// Имя файла: «имя-исходника 01 заголовок.mp4», безопасно для ФС и уникально.
    static func fileURL(in folder: URL, sourceName: String, index: Int, title: String) -> URL {
        let base = "\(sourceName) \(String(format: "%02d", index + 1)) \(sanitize(title))"
        var url = folder.appendingPathComponent("\(base).mp4")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) (\(counter)).mp4")
            counter += 1
        }
        return url
    }

    static func sanitize(_ title: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\?%*:|\"<>:").union(.newlines)
        let cleaned = title.components(separatedBy: illegal).joined(separator: " ")
        let collapsed = cleaned.split(separator: " ").joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "ролик" }
        return String(trimmed.prefix(50)).trimmingCharacters(in: .whitespaces)
    }

}
