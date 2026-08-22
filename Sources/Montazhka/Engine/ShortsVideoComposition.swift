import AVFoundation
import Foundation

/// Единый результат подготовки видео для предпросмотра и экспорта.
struct ShortsVideoCompositionPlan {
    let videoComposition: AVMutableVideoComposition?
    let croppedRenderSize: CGSize?
}

/// Единая точка сборки crop-композиции и offline-слоя субтитров.
/// Preview использует этот builder для кропа, а текст рисует SwiftUI-слоем;
/// export добавляет сюда Core Animation для запекания в MP4.
enum ShortsVideoCompositionBuilder {
    static func make(
        asset: AVAsset,
        displaySize: CGSize,
        cropVertical: Bool,
        subtitleMode: ShortsSubtitleMode,
        subtitleTimeline: ShortsSubtitleTimeline
    ) async -> ShortsVideoCompositionPlan {
        let crop =
            cropVertical
            ? await verticalCropComposition(for: asset, displaySize: displaySize)
            : nil

        let base: AVMutableVideoComposition?
        if let crop {
            base = crop
        } else {
            switch subtitleMode {
            case .off:
                base = nil
            case .on:
                base = try? await AVMutableVideoComposition.videoComposition(
                    withPropertiesOf: asset)
            }
        }

        guard let base else {
            return ShortsVideoCompositionPlan(videoComposition: nil, croppedRenderSize: nil)
        }

        let videoComposition: AVMutableVideoComposition
        switch subtitleMode {
        case .off:
            videoComposition = base
        case let .on(words, style, size):
            let cues = ShortsSubtitleCueBuilder.make(
                words: words,
                sourceStart: subtitleTimeline.sourceStart,
                sourceEnd: subtitleTimeline.sourceEnd,
                relativeTo: subtitleTimeline.relativeTo)
            videoComposition = ShortsSubtitleRenderer.applying(
                base,
                cues: cues,
                style: style,
                size: size,
                duration: subtitleTimeline.duration)
        }

        return ShortsVideoCompositionPlan(
            videoComposition: videoComposition,
            croppedRenderSize: crop?.renderSize)
    }

    /// Видеокомпозиция с вырезом 9:16 по центру кадра. Возвращает nil, если
    /// кадр уже вертикальный или что-то не удалось прочитать.
    private static func verticalCropComposition(
        for asset: AVAsset,
        displaySize: CGSize
    ) async -> AVMutableVideoComposition? {
        guard displaySize.width > displaySize.height else { return nil }
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
            let transform = try? await track.load(.preferredTransform)
        else { return nil }
        let frameRate = (try? await track.load(.nominalFrameRate)) ?? 30
        let duration = (try? await asset.load(.duration)) ?? .zero
        guard duration.seconds > 0 else { return nil }

        let cropWidth = even(floor(abs(displaySize.height) * 9 / 16))
        let cropX = (abs(displaySize.width) - cropWidth) / 2
        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(
            width: cropWidth,
            height: even(abs(displaySize.height)))
        composition.frameDuration = CMTime(
            value: 1,
            timescale: max(24, Int32(frameRate.rounded())))

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(
            transform.concatenating(CGAffineTransform(translationX: -cropX, y: 0)),
            at: .zero)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]
        return composition
    }

    private static func even(_ value: CGFloat) -> CGFloat {
        max(2, (value / 2).rounded() * 2)
    }
}
