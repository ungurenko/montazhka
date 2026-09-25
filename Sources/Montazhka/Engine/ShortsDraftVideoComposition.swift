@preconcurrency import AVFoundation
import CoreGraphics
import Foundation

/// Видеокомпозиция черновика шортса: вертикальный холст, рамка за лицом,
/// плавные наезды, раскладка «экран + лицо». Геометрию считает
/// `ShortsCameraPlanner`, здесь она только превращается в инструкции AVFoundation.
enum ShortsDraftVideoComposition {
    static func make(
        asset: AVAsset, clips: [Clip], layout: ShortsDraftLayout,
        centre: @escaping ShortsCameraPlanner.Centre, zooms: [ShortsZoom],
        faceBox: CGRect?, canvas: CGSize
    ) async throws -> AVMutableVideoComposition {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let first = tracks.first else { throw ShortsVideoCompositionError.invalidVideoTrack }
        let natural = try await first.load(.naturalSize)
        let preferred = try await first.load(.preferredTransform)
        let frameRate = try await first.load(.nominalFrameRate)
        let duration = try await asset.load(.duration)
        let oriented = CGRect(origin: .zero, size: natural).applying(preferred)
        let display = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        guard display.width > 0, display.height > 0, duration.seconds > 0 else {
            throw ShortsVideoCompositionError.invalidVideoTrack
        }
        let normalized = preferred.concatenating(
            CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY))

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)

        if layout == .split, tracks.count >= 2,
            let split = ShortsCameraPlanner.split(display: display, canvas: canvas, faceBox: faceBox)
        {
            let screen = AVMutableVideoCompositionLayerInstruction(assetTrack: tracks[0])
            screen.setTransform(
                ShortsCameraPlanner.transform(
                    crop: CGRect(origin: .zero, size: display), into: split.screen, normalized: normalized),
                at: .zero)
            let faceCentre = CGPoint(x: split.faceCrop.midX / display.width, y: split.faceCrop.midY / display.height)
            let keys = ShortsCameraPlanner.keys(
                clips: clips, display: display, layout: .face, centre: { _, _ in faceCentre }, zooms: zooms,
                aspect: split.faceRegion.width / split.faceRegion.height, base: split.faceCrop.size)
            let face = AVMutableVideoCompositionLayerInstruction(assetTrack: tracks[1])
            apply(keys, to: face, region: split.faceRegion, normalized: normalized, cropsTo: normalized.inverted())
            instruction.layerInstructions = [face, screen]
        } else {
            let resolved: ShortsDraftLayout = layout == .fit ? .fit : .face
            let keys = ShortsCameraPlanner.keys(
                clips: clips, display: display, layout: resolved, centre: centre, zooms: zooms)
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: first)
            apply(keys, to: layer, region: CGRect(origin: .zero, size: canvas), normalized: normalized, cropsTo: nil)
            instruction.layerInstructions = [layer]
        }

        let composition = AVMutableVideoComposition()
        composition.renderSize = canvas
        composition.frameDuration = CMTime(value: 1, timescale: max(24, Int32(frameRate.rounded())))
        composition.instructions = [instruction]
        return composition
    }

    /// Ключи → рампы преобразования. Между клипами рамп нет: на склейке кадр
    /// встаёт на место сразу. `cropsTo` — обрезать картинку по рамке (нужно,
    /// когда слой занимает только часть холста); это обратный поворот дорожки.
    private static func apply(
        _ keys: [ShortsCameraPlanner.Key], to layer: AVMutableVideoCompositionLayerInstruction,
        region: CGRect, normalized: CGAffineTransform, cropsTo inverse: CGAffineTransform?
    ) {
        func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }
        func transform(_ key: ShortsCameraPlanner.Key) -> CGAffineTransform {
            ShortsCameraPlanner.transform(crop: key.rect, into: region, normalized: normalized)
        }
        // Каждый отрезок между соседними ключами одного клипа задаёт ровно
        // одно: рамп, если кадр движется, или неподвижное значение. Последний
        // ключ клипа ничего не задаёт — с этого момента действует следующий клип.
        for (a, b) in zip(keys, keys.dropFirst()) where a.clip == b.clip && b.time > a.time {
            if a.rect == b.rect {
                layer.setTransform(transform(a), at: time(a.time))
                if let inverse { layer.setCropRectangle(a.rect.applying(inverse), at: time(a.time)) }
                continue
            }
            let range = CMTimeRange(start: time(a.time), end: time(b.time))
            layer.setTransformRamp(fromStart: transform(a), toEnd: transform(b), timeRange: range)
            if let inverse {
                layer.setCropRectangleRamp(
                    fromStartCropRectangle: a.rect.applying(inverse),
                    toEndCropRectangle: b.rect.applying(inverse), timeRange: range)
            }
        }
    }
}
