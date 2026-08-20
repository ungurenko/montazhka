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
        to url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let clip = Clip(sourceURL: sourceURL, start: candidate.start, end: candidate.end)
        let built = await CompositionBuilder.build(clips: [clip])

        let crop =
            cropVertical
            ? await verticalCropComposition(for: built.composition, displaySize: displaySize)
            : nil
        let dimensions = crop?.renderSize ?? quality.targetDimensions(forDisplaySize: displaySize)
        let settings = Transcoder.Settings(
            dimensions: dimensions,
            videoBitrate: quality.videoBitrate(forDimensions: dimensions),
            audioBitrate: quality.audioBitrate)
        try await Transcoder.export(
            input: ExportInput(
                composition: built.composition,
                audioMix: built.audioMix,
                videoComposition: crop),
            settings: settings,
            to: url,
            progress: progress)
    }

    /// Видеокомпозиция с вырезом 9:16 по центру кадра. Возвращает nil, если
    /// кадр уже вертикальный или что-то не удалось прочитать.
    static func verticalCropComposition(
        for composition: AVAsset,
        displaySize: CGSize
    ) async -> AVMutableVideoComposition? {
        guard displaySize.width > displaySize.height else { return nil }
        guard let track = try? await composition.loadTracks(withMediaType: .video).first,
            let transform = try? await track.load(.preferredTransform)
        else { return nil }
        let frameRate = (try? await track.load(.nominalFrameRate)) ?? 30
        let duration = (try? await composition.load(.duration)) ?? .zero
        guard duration.seconds > 0 else { return nil }

        let cropWidth = even(floor(abs(displaySize.height) * 9 / 16))
        let cropX = (abs(displaySize.width) - cropWidth) / 2
        let compositionVideoComposition = AVMutableVideoComposition()
        compositionVideoComposition.renderSize = CGSize(width: cropWidth, height: even(abs(displaySize.height)))
        compositionVideoComposition.frameDuration = CMTime(value: 1, timescale: max(24, Int32(frameRate.rounded())))

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(
            transform.concatenating(CGAffineTransform(translationX: -cropX, y: 0)),
            at: .zero)
        instruction.layerInstructions = [layer]
        compositionVideoComposition.instructions = [instruction]
        return compositionVideoComposition
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

    private static func even(_ value: CGFloat) -> CGFloat {
        max(2, (value / 2).rounded() * 2)
    }
}
