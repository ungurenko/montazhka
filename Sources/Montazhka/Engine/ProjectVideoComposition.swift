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
    /// Основа и анимации: предпросмотр и кадры агента.
    let frameComposition: AVMutableVideoComposition
    /// То же и субтитры слоем Core Animation поверх всего — для MP4.
    let exportComposition: AVMutableVideoComposition
    /// Субтитры картинкой для кадров агента.
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

        var errorDescription: String? {
            switch self {
            case .noBaseVideo: "Не удалось подготовить кадр проекта: в нём нет видео."
            case .missingTrack: "Не удалось подготовить кадр проекта: дорожка анимации пропала из склейки."
            }
        }
    }

    /// Отступ анимации в углу — доля ширины и высоты кадра.
    static let cornerMargin: CGFloat = 0.04

    /// nil, когда нет ни анимаций, ни вшитых субтитров: экспорт и предпросмотр — как раньше.
    /// Одна инструкция на всю длину: анимации сверху вниз от последней к первой, база под ними.
    /// Непрозрачность анимации 0 до окна и после него: иначе после конца своего куска
    /// дорожка держит последний кадр до конца ролика.
    static func make(
        composition: AVComposition, baseTrackID: CMPersistentTrackID, overlays: [OverlayTrack],
        subtitles: ProjectSubtitleLayer?, duration: Double
    ) async throws -> ProjectVideoPlan? {
        guard !overlays.isEmpty || subtitles != nil else { return nil }
        guard let base = try await composition.loadTrack(withTrackID: baseTrackID) else { throw BuildError.noBaseVideo }
        let (natural, preferred, frameRate) = try await base.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let length = try await composition.load(.duration)
        let oriented = CGRect(origin: .zero, size: natural).applying(preferred)
        let renderSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        guard renderSize.width > 0, renderSize.height > 0, length > .zero else { throw BuildError.noBaseVideo }

        let baseLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: base)
        baseLayer.setTransform(
            preferred.concatenating(CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY)), at: .zero)
        // Обрезка по всему кадру ничего не отрезает, но заставляет честно смешивать каждый
        // кадр. Иначе кадр с одной основой как есть сессия экспорта пропускает мимо
        // смешивания, и под слоем субтитров (Core Animation) он выходит белым.
        baseLayer.setCropRectangle(CGRect(origin: .zero, size: natural), at: .zero)
        var layers: [AVVideoCompositionLayerInstruction] = [baseLayer]
        for overlay in overlays {
            guard let track = try await composition.loadTrack(withTrackID: overlay.trackID) else {
                throw BuildError.missingTrack
            }
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            layer.setTransform(
                overlayTransform(
                    naturalSize: overlay.naturalSize, preferredTransform: overlay.preferredTransform,
                    position: overlay.position, scale: overlay.scale, renderSize: renderSize),
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
        let fps = frameRate.isFinite && frameRate > 0 ? Int32(frameRate.rounded()) : 30
        frame.frameDuration = CMTime(value: 1, timescale: max(1, fps))
        frame.instructions = [instruction]

        guard let export = frame.mutableCopy() as? AVMutableVideoComposition else { throw BuildError.noBaseVideo }
        guard let subtitles else {
            return ProjectVideoPlan(frameComposition: frame, exportComposition: export, overlayImageAt: nil)
        }
        return ProjectVideoPlan(
            frameComposition: frame,
            exportComposition: ShortsSubtitleRenderer.applying(
                export, cues: subtitles.cues, appearance: subtitles.appearance, highlight: subtitles.highlight,
                duration: duration),
            overlayImageAt: { time in
                ShortsOverlaySnapshot.image(
                    at: time, renderSize: renderSize, cues: subtitles.cues, appearance: subtitles.appearance,
                    highlight: subtitles.highlight, hook: nil)
            })
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
