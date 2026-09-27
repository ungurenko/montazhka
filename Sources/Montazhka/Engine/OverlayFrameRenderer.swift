import AppKit
import CoreGraphics
import QuartzCore

/// Надписи (хук и фразы) поверх кадра — для записи MP4 и для кадров агента. Слой строится
/// один раз тем же `ShortsSubtitleRenderer.overlayLayer`; картинка рисуется заново, только
/// когда меняется видимое: фраза, подсвеченное слово, хук, шаг затухания хука.
/// Под замком: запись и кадры агента могут звать её с разных потоков.
final class OverlayFrameRenderer: @unchecked Sendable {
    private struct Timed {
        let layer: CALayer
        let from: Double
        let to: Double
        let fade: Double
    }

    private let lock = NSLock()
    private let root: CALayer
    private let renderSize: CGSize
    private let timed: [Timed]
    private var shown: [Float]?
    private var image: CGImage?

    /// nil — рисовать нечего: ни фраз, ни хука.
    init?(
        renderSize: CGSize, cues: [ShortsSubtitleCue], appearance: ShortsSubtitleAppearance, highlight: Bool,
        hook: ShortsHook?
    ) {
        let hook = hook.flatMap { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        guard !cues.isEmpty || hook != nil, renderSize.width > 0, renderSize.height > 0 else { return nil }
        let duration = max(hook?.duration ?? 0, cues.map(\.end).max() ?? 0) + 1
        root = ShortsSubtitleRenderer.overlayLayer(
            renderSize: renderSize, cues: cues, appearance: appearance, highlight: highlight, duration: duration,
            hook: hook)
        self.renderSize = renderSize
        var timed: [Timed] = []
        Self.collect(root, into: &timed)
        self.timed = timed
    }

    /// Надписи в момент ленты; nil — в этот момент не видно ничего.
    func image(at time: Double) -> CGImage? {
        lock.withLock {
            let state = timed.map { Float(Self.opacity(of: $0, at: time)) }
            if state == shown { return image }
            shown = state
            guard state.contains(where: { $0 > 0 }) else {
                image = nil
                return nil
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (item, opacity) in zip(timed, state) { item.layer.opacity = opacity }
            CATransaction.commit()
            image = render()
            return image
        }
    }

    /// Видимость по окну слоя — так же, как у анимации экспорта: включение и выключение
    /// жёсткие, затухание — линейное до нуля к концу окна.
    private static func opacity(of item: Timed, at time: Double) -> Double {
        guard time >= item.from, time < item.to else { return 0 }
        guard item.fade > 0, time > item.to - item.fade else { return 1 }
        return max(0, (item.to - time) / item.fade)
    }

    /// Слои с окном видимости; анимации снимаются — видимость задаёт `image(at:)`.
    private static func collect(_ layer: CALayer, into timed: inout [Timed]) {
        layer.removeAllAnimations()
        if let from = layer.value(forKey: ShortsSubtitleRenderer.visibleFromKey) as? Double,
            let to = layer.value(forKey: ShortsSubtitleRenderer.visibleToKey) as? Double
        {
            let fade = layer.value(forKey: ShortsSubtitleRenderer.visibleFadeKey) as? Double ?? 0
            timed.append(Timed(layer: layer, from: from, to: to, fade: fade))
        }
        for sublayer in layer.sublayers ?? [] { collect(sublayer, into: &timed) }
    }

    private func render() -> CGImage? {
        guard
            let context = CGContext(
                data: nil, width: Int(renderSize.width), height: Int(renderSize.height),
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        root.render(in: context)
        return context.makeImage()
    }
}
