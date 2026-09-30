@preconcurrency import AVFoundation
import CoreGraphics
import Foundation

/// Видеотрек одной анимации поверх основной картинки.
/// @unchecked Sendable: только значения, после сборки не меняются.
struct OverlayTrack: @unchecked Sendable {
    let overlayID: UUID
    let trackID: CMPersistentTrackID
    /// Когда анимация видна на ленте.
    let window: TimelineRange
    let naturalSize: CGSize
    let preferredTransform: CGAffineTransform
    let position: OverlayPosition
    let scale: Double
}

/// Субтитры, впечатанные в кадр обычного проекта.
struct ProjectSubtitleLayer: Sendable {
    let cues: [ShortsSubtitleCue]
    let appearance: ShortsSubtitleAppearance
    let highlight: Bool
}

/// Картинка обычного проекта с анимациями и субтитрами.
/// @unchecked Sendable: композиции после сборки не меняются, их только читают.
struct ProjectVideoPlan: @unchecked Sendable {
    /// Основа и анимации: предпросмотр, кадры агента и MP4.
    let frameComposition: AVMutableVideoComposition
    /// Вшитые субтитры картинкой поверх кадра — для кадров агента и MP4 одним рисовальщиком.
    let overlayImageAt: (@Sendable (Double) -> CGImage?)?
}

extension ProjectSubtitleLayer {
    /// Вшитые фразы в сохранённом оформлении субтитров; nil — вшивать нечего.
    static func saved(cues: [ShortsSubtitleCue]?) -> ProjectSubtitleLayer? {
        guard let cues, !cues.isEmpty else { return nil }
        let settings = ShortsSubtitleSettings.saved()
        return ProjectSubtitleLayer(
            cues: cues, appearance: settings.appearance, highlight: settings.highlightActiveWord)
    }
}

enum ProjectVideoComposition {
    enum BuildError: LocalizedError {
        case noBaseVideo
        case missingTrack
        case invalidRenderSize

        var errorDescription: String? {
            switch self {
            case .noBaseVideo: "Не удалось подготовить кадр проекта: в нём нет видео."
            case .missingTrack: "Не удалось подготовить кадр проекта: дорожка анимации пропала из склейки."
            case .invalidRenderSize: "Не удалось подготовить кадр проекта: неверный размер кадра."
            }
        }
    }

    /// Отступ анимации в углу — доля ширины и высоты кадра.
    static let cornerMargin: CGFloat = 0.04

    /// nil, когда отсутствуют анимации, субтитры, особая геометрия и запрос размера:
    /// экспорт и предпросмотр — как раньше.
    /// Одна инструкция на всю длину: анимации сверху вниз от последней к первой, база под ними.
    /// Непрозрачность анимации 0 до окна и после него: иначе после конца своего куска
    /// дорожка держит последний кадр до конца ролика.
    /// `segments` — куски основы с геометрией их исходников, когда она разная: кадр ролика —
    /// как у первого куска, остальные вписываются в него целиком по центру, поля чёрные.
    static func make(
        composition: AVComposition, baseTrackID: CMPersistentTrackID, overlays: [OverlayTrack],
        subtitles: ProjectSubtitleLayer?, segments: [VideoSegmentGeometry] = [], freezeAt: Double? = nil,
        targetRenderSize: CGSize? = nil
    ) async throws -> ProjectVideoPlan? {
        guard !overlays.isEmpty || subtitles != nil || !segments.isEmpty || targetRenderSize != nil else { return nil }
        guard let base = try await composition.loadTrack(withTrackID: baseTrackID) else { throw BuildError.noBaseVideo }
        let (trackNatural, trackPreferred, frameRate) = try await base.load(
            .naturalSize, .preferredTransform, .nominalFrameRate)
        let natural = segments.first?.naturalSize ?? trackNatural
        let preferred = segments.first?.preferredTransform ?? trackPreferred
        let length = try await composition.load(.duration)
        let oriented = CGRect(origin: .zero, size: natural).applying(preferred)
        let nativeSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        guard nativeSize.width > 0, nativeSize.height > 0, length > .zero else { throw BuildError.noBaseVideo }
        let renderSize = targetRenderSize ?? nativeSize
        guard renderSize.width.isFinite, renderSize.height.isFinite, renderSize.width > 0, renderSize.height > 0
        else { throw BuildError.invalidRenderSize }
        let outputScale = CGAffineTransform(
            scaleX: renderSize.width / nativeSize.width, y: renderSize.height / nativeSize.height)

        let baseLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: base)
        // Обрезка по всему кадру ничего не отрезает, но заставляет честно смешивать каждый
        // кадр: кадр с одной основой как есть AVFoundation может пропустить мимо смешивания.
        let whole = VideoSegmentGeometry(
            timeRange: CMTimeRange(start: .zero, duration: length), naturalSize: natural, preferredTransform: preferred)
        for piece in segments.isEmpty ? [whole] : segments {
            let fitted = fittedTransform(
                naturalSize: piece.naturalSize, preferredTransform: piece.preferredTransform, renderSize: nativeSize)
            baseLayer.setTransform(
                targetRenderSize == nil ? fitted : fitted.concatenating(outputScale), at: piece.timeRange.start)
            baseLayer.setCropRectangle(CGRect(origin: .zero, size: piece.naturalSize), at: piece.timeRange.start)
        }
        var layers: [AVVideoCompositionLayerInstruction] = [baseLayer]
        for overlay in overlays {
            guard let track = try await composition.loadTrack(withTrackID: overlay.trackID) else {
                throw BuildError.missingTrack
            }
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            let placed = overlayTransform(
                naturalSize: overlay.naturalSize, preferredTransform: overlay.preferredTransform,
                position: overlay.position, scale: overlay.scale, renderSize: nativeSize)
            layer.setTransform(
                targetRenderSize == nil ? placed : placed.concatenating(outputScale),
                at: .zero)
            let start = CMTime(seconds: overlay.window.from, preferredTimescale: 60_000)
            if start > .zero { layer.setOpacity(0, at: .zero) }
            layer.setOpacity(1, at: start)
            layer.setOpacity(0, at: CMTime(seconds: overlay.window.to, preferredTimescale: 60_000))
            layers.insert(layer, at: 0)
        }
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: length)
        instruction.layerInstructions = layers

        let frame = AVMutableVideoComposition()
        frame.renderSize = renderSize
        frame.frameDuration = frameDuration(nominalFrameRate: frameRate)
        frame.instructions = [instruction]
        // Цвет — как у обычного экспорта той же ленты без анимаций. nil у AVFoundation
        // значит «цвет исходника»: так выходит и для SDR, и для HLG.
        let plain = try await plainComposition(of: composition, baseTrackID: baseTrackID)
        frame.colorPrimaries = plain.colorPrimaries
        frame.colorTransferFunction = plain.colorTransferFunction
        frame.colorYCbCrMatrix = plain.colorYCbCrMatrix

        let overlay = subtitles.flatMap {
            OverlayFrameRenderer(
                renderSize: nativeSize, cues: $0.cues, appearance: $0.appearance, highlight: $0.highlight, hook: nil)
        }
        let imageAt: (@Sendable (Double) -> CGImage?)?
        if let renderer = overlay {
            imageAt = { time in renderer.image(at: min(time, freezeAt ?? time)) }
        } else {
            imageAt = nil
        }
        return ProjectVideoPlan(frameComposition: frame, overlayImageAt: imageAt)
    }

    /// Шаг кадров ровно как у обычного экспорта (`videoComposition(withPropertiesOf:)`):
    /// 1/nominalFrameRate на шкале 90000, без округления частоты — 29,97 к/с не становятся 30.
    /// Самый короткий кадр не годится: у съёмки iPhone с плавающей частотой он 9/600 с (66,7 к/с).
    static func frameDuration(nominalFrameRate rate: Float) -> CMTime {
        guard rate.isFinite, rate > 0 else { return CMTime(value: 1, timescale: 30) }
        return CMTime(value: CMTimeValue((90_000 / Double(rate)).rounded()), timescale: 90_000)
    }

    /// Что собрал бы обычный экспорт по одной основе. Дорожки анимаций убираются из копии:
    /// с ними AVFoundation берёт шаг и цвет с учётом анимаций (30 к/с ProRes поверх 29,97).
    private static func plainComposition(
        of composition: AVComposition, baseTrackID: CMPersistentTrackID
    ) async throws -> AVMutableVideoComposition {
        guard let baseOnly = composition.mutableCopy() as? AVMutableComposition else { throw BuildError.noBaseVideo }
        for track in try await baseOnly.loadTracks(withMediaType: .video) where track.trackID != baseTrackID {
            baseOnly.removeTrack(track)
        }
        return try await AVMutableVideoComposition.videoComposition(withPropertiesOf: baseOnly)
    }

    /// Кусок исходника с его поворотом, вписанный в кадр ролика целиком и по центру.
    static func fittedTransform(
        naturalSize: CGSize, preferredTransform: CGAffineTransform, renderSize: CGSize
    ) -> CGAffineTransform {
        overlayTransform(
            naturalSize: naturalSize, preferredTransform: preferredTransform, position: .full, scale: 1,
            renderSize: renderSize)
    }

    /// Где анимация в кадре. `.full` — вписана целиком по центру; `.center` — вписана и
    /// уменьшена в `scale` раз; углы — вписана, уменьшена в `scale` раз и прижата к углу
    /// с отступом `cornerMargin`. Координаты кадра AVFoundation: начало слева сверху.
    static func overlayTransform(
        naturalSize: CGSize, preferredTransform: CGAffineTransform, position: OverlayPosition, scale: Double,
        renderSize: CGSize
    ) -> CGAffineTransform {
        let oriented = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let size = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        guard size.width > 0, size.height > 0 else { return preferredTransform }
        let fit = min(renderSize.width / size.width, renderSize.height / size.height)
        let factor = position == .full ? fit : fit * CGFloat(scale.isFinite && scale > 0 ? scale : 1)
        let drawn = CGSize(width: size.width * factor, height: size.height * factor)
        let margin = CGSize(width: renderSize.width * cornerMargin, height: renderSize.height * cornerMargin)
        let left = margin.width
        let right = renderSize.width - drawn.width - margin.width
        let top = margin.height
        let bottom = renderSize.height - drawn.height - margin.height
        let origin: CGPoint
        switch position {
        case .full, .center:
            origin = CGPoint(x: (renderSize.width - drawn.width) / 2, y: (renderSize.height - drawn.height) / 2)
        case .topLeft: origin = CGPoint(x: left, y: top)
        case .topRight: origin = CGPoint(x: right, y: top)
        case .bottomLeft: origin = CGPoint(x: left, y: bottom)
        case .bottomRight: origin = CGPoint(x: right, y: bottom)
        }
        return
            preferredTransform
            .concatenating(CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY))
            .concatenating(CGAffineTransform(scaleX: factor, y: factor))
            .concatenating(CGAffineTransform(translationX: origin.x, y: origin.y))
    }
}
