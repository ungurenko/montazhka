@preconcurrency import AVFoundation
import Foundation

/// Экспорт одного ролика: композиция диапазона исходника, опциональный
/// вертикальный кадр 9:16 и перекодирование с выбранным качеством.
enum ShortsExporter {
    static func export(
        candidate: ShortCandidate,
        timeMap: ShortsTimeMap,
        sourceURL: URL,
        displaySize: CGSize,
        quality: ExportQuality,
        frameSettings: ShortsFrameSettings,
        subtitleMode: ShortsSubtitleMode = .off,
        to url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let built = await CompositionBuilder.build(clips: clips(for: timeMap, sourceURL: sourceURL))

        let plan = try await ShortsVideoCompositionBuilder.make(
            asset: built.composition,
            frameRequest: frameSettings.exportRequest(quality: quality),
            subtitleMode: subtitleMode,
            subtitleTimeMap: timeMap)
        let dimensions =
            plan.outputRenderSize
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

    /// Куски исходника, из которых собирается ролик. Вырезанные паузы просто
    /// не попадают в список — склейки и микрофейды делает CompositionBuilder.
    static func clips(for timeMap: ShortsTimeMap, sourceURL: URL) -> [Clip] {
        timeMap.segments.map { Clip(sourceURL: sourceURL, start: $0.start, end: $0.end) }
    }

    /// Собирает композицию для плеера. Предпросмотр и экспорт строятся из одной
    /// и той же карты времени, поэтому шкала у них общая: ролик всегда идёт
    /// с нуля, а текст рисуется поверх SwiftUI-слоем.
    static func previewComposition(
        for asset: AVAsset,
        frameSettings: ShortsFrameSettings
    ) async throws -> AVMutableVideoComposition? {
        let plan = try await ShortsVideoCompositionBuilder.make(
            asset: asset,
            frameRequest: frameSettings.previewRequest,
            subtitleMode: .off,
            subtitleTimeMap: .single(start: 0, end: 0))
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
