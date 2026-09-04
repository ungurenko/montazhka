@preconcurrency import AVFoundation
import CoreGraphics
import Foundation

/// Единый результат подготовки видео для предпросмотра и экспорта.
struct ShortsVideoCompositionPlan {
    let videoComposition: AVMutableVideoComposition?
    let outputRenderSize: CGSize?
}

enum ShortsVideoCompositionError: LocalizedError {
    case invalidVideoTrack

    var errorDescription: String? {
        "Не удалось подготовить вертикальный кадр. Проверь исходное видео."
    }
}

/// Единая точка сборки crop-композиции и offline-слоя субтитров.
/// Preview использует этот builder для кропа, а текст рисует SwiftUI-слоем;
/// export добавляет сюда Core Animation для запекания в MP4.
enum ShortsVideoCompositionBuilder {
    static func make(
        asset: AVAsset,
        frameRequest: ShortsFrameRequest,
        subtitleMode: ShortsSubtitleMode,
        subtitleTimeMap: ShortsTimeMap
    ) async throws -> ShortsVideoCompositionPlan {
        let frameComposition: AVMutableVideoComposition?
        switch frameRequest {
        case .original:
            frameComposition = nil
        case .verticalCrop:
            frameComposition = verticalCropComposition(
                geometry: try await loadGeometry(for: asset))
        case let .verticalFit(color, resolution):
            let geometry = try await loadGeometry(for: asset)
            let quality: ExportQuality? =
                switch resolution {
                case .source: nil
                case let .quality(value): value
                }
            let renderSize = ShortsFrameLayout.verticalCanvasSize(
                for: geometry.displaySize, quality: quality)
            frameComposition = try verticalFitComposition(
                geometry: geometry,
                renderSize: renderSize,
                canvasColor: color)
        }

        let base: AVMutableVideoComposition?
        if let frameComposition {
            base = frameComposition
        } else {
            switch subtitleMode {
            case .off:
                base = nil
            case .on:
                base = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
            }
        }

        guard let base else {
            return ShortsVideoCompositionPlan(videoComposition: nil, outputRenderSize: nil)
        }

        let videoComposition: AVMutableVideoComposition
        switch subtitleMode {
        case .off:
            videoComposition = base
        case let .on(words, appearance, highlight):
            let cues = ShortsSubtitleCueBuilder.make(words: words, timeMap: subtitleTimeMap)
            videoComposition = ShortsSubtitleRenderer.applying(
                base,
                cues: cues,
                appearance: appearance,
                highlight: highlight,
                duration: subtitleTimeMap.outputDuration)
        }

        return ShortsVideoCompositionPlan(
            videoComposition: videoComposition,
            outputRenderSize: frameComposition?.renderSize)
    }

    /// Видеокомпозиция с вырезом 9:16 по центру кадра. Возвращает nil,
    /// если кадр уже вертикальный; ошибки чтения не скрывает.
    private static func verticalCropComposition(
        geometry: VideoGeometry
    ) -> AVMutableVideoComposition? {
        guard geometry.displaySize.width > geometry.displaySize.height else { return nil }

        let cropWidth = even(floor(geometry.displaySize.height * 9 / 16))
        let cropX = (geometry.displaySize.width - cropWidth) / 2
        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(
            width: cropWidth,
            height: even(geometry.displaySize.height))
        composition.frameDuration = CMTime(
            value: 1,
            timescale: max(24, Int32(geometry.frameRate.rounded())))

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: geometry.duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: geometry.track)
        layer.setTransform(
            geometry.normalizedTransform.concatenating(
                CGAffineTransform(translationX: -cropX, y: 0)),
            at: .zero)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]
        return composition
    }

    private static func verticalFitComposition(
        geometry: VideoGeometry,
        renderSize: CGSize,
        canvasColor: ShortsCanvasColor
    ) throws -> AVMutableVideoComposition {
        let layout = ShortsFrameLayout.verticalFit(
            displaySize: geometry.displaySize,
            renderSize: renderSize)
        guard layout.contentRect.width > 0, layout.contentRect.height > 0 else {
            throw ShortsVideoCompositionError.invalidVideoTrack
        }

        let scale = layout.contentRect.width / geometry.displaySize.width
        let transform =
            geometry.normalizedTransform
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(
                CGAffineTransform(
                    translationX: layout.contentRect.minX,
                    y: layout.contentRect.minY))

        let composition = AVMutableVideoComposition()
        composition.renderSize = layout.renderSize
        composition.frameDuration = CMTime(
            value: 1,
            timescale: max(24, Int32(geometry.frameRate.rounded())))

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: geometry.duration)
        instruction.backgroundColor =
            canvasColor == .black
            ? CGColor(red: 0, green: 0, blue: 0, alpha: 1)
            : CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: geometry.track)
        layer.setTransform(transform, at: .zero)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]
        return composition
    }

    private struct VideoGeometry {
        let track: AVAssetTrack
        let displaySize: CGSize
        let normalizedTransform: CGAffineTransform
        let frameRate: Float
        let duration: CMTime
    }

    private static func loadGeometry(for asset: AVAsset) async throws -> VideoGeometry {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ShortsVideoCompositionError.invalidVideoTrack
        }
        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let frameRate = try await track.load(.nominalFrameRate)
        let duration = try await asset.load(.duration)
        let orientedBounds = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let displaySize = CGSize(width: abs(orientedBounds.width), height: abs(orientedBounds.height))
        guard naturalSize.width > 0, naturalSize.height > 0,
            displaySize.width > 0, displaySize.height > 0, duration.seconds > 0
        else { throw ShortsVideoCompositionError.invalidVideoTrack }
        return VideoGeometry(
            track: track,
            displaySize: displaySize,
            normalizedTransform: preferredTransform.concatenating(
                CGAffineTransform(
                    translationX: -orientedBounds.minX,
                    y: -orientedBounds.minY)),
            frameRate: frameRate,
            duration: duration)
    }

    private static func even(_ value: CGFloat) -> CGFloat {
        max(2, (value / 2).rounded() * 2)
    }
}
