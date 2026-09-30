import AppKit
import CoreGraphics
import QuartzCore

/// Надписи для записи MP4 и кадров агента. Раскладка прежняя, растры создаются
/// только для активных фраз. Неактивные фразы сохраняются в ограниченном LRU-кэше.
/// Под замком: запись и кадры агента могут звать её с разных потоков.
final class OverlayFrameRenderer: @unchecked Sendable {
    private struct Entry {
        let layer: CALayer
        let timed: [SubtitleLayerPlan.Timed]
        let cost: Int
        var access: UInt64
    }

    private struct Shown: Equatable {
        let indices: [Int]
        let opacities: [Float]
    }

    private let lock = NSLock()
    private let root: CALayer
    private let renderSize: CGSize
    private let cues: [ShortsSubtitleCue]
    private let windows: [TimelineRange]
    private let appearance: ShortsSubtitleAppearance
    private let highlight: Bool
    private let hook: ShortsHook?
    private let duration: Double
    private let cacheCostLimit: Int
    private var cache: [Int: Entry] = [:]
    private var cacheCost = 0
    private var access: UInt64 = 0
    private var shown: Shown?
    private var image: CGImage?

    /// nil — рисовать нечего: ни фраз, ни хука. Нулевой кэш удерживает только активную сцену.
    init?(
        renderSize: CGSize, cues: [ShortsSubtitleCue], appearance: ShortsSubtitleAppearance, highlight: Bool,
        hook: ShortsHook?, cacheCostLimit: Int = 32 * 1024 * 1024
    ) {
        let hook = hook.flatMap { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        guard !cues.isEmpty || hook != nil, renderSize.width > 0, renderSize.height > 0 else { return nil }
        self.cues = cues
        // ASR-слова могут пересекаться и выходить за окно родительской фразы.
        // Прежний renderer в таком случае возвращает прозрачный кадр, а не nil.
        self.windows = cues.map { cue in
            TimelineRange(
                from: highlight ? min(cue.start, cue.words.map(\.start).min() ?? cue.start) : cue.start,
                to: highlight ? max(cue.end, cue.words.map(\.end).max() ?? cue.end) : cue.end)
        }
        self.appearance = appearance
        self.highlight = highlight
        self.hook = hook
        self.duration = max(hook?.duration ?? 0, cues.map(\.end).max() ?? 0) + 1
        self.renderSize = renderSize
        self.cacheCostLimit = max(0, cacheCostLimit)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root = CALayer()
        root.frame = CGRect(origin: .zero, size: renderSize)
        CATransaction.commit()
    }

    /// Стоимость уникальных растров; активная сцена может превышать предел кэша.
    var cachedImageBytes: Int { lock.withLock { cacheCost } }

    /// Надписи в момент ленты; nil — в этот момент не видно ничего.
    func image(at time: Double) -> CGImage? {
        lock.withLock {
            autoreleasepool {
                // Создание фразы тоже меняет CALayer. Не оставляем неявную
                // транзакцию на фоновой очереди без RunLoop: она удержит вытесненные растры.
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                defer { CATransaction.commit() }
                var indices = windows.indices.filter { time >= windows[$0].from && time < windows[$0].to }
                if let hook, time >= 0, time < hook.duration { indices.append(cues.count) }
                access &+= 1
                for index in indices {
                    if cache[index] == nil {
                        let entry = makeEntry(index: index)
                        cache[index] = entry
                        cacheCost += entry.cost
                    }
                    cache[index]?.access = access
                }
                let timed = indices.flatMap { cache[$0]?.timed ?? [] }
                let state = Shown(indices: indices, opacities: timed.map { $0.opacity(at: time) })
                if state == shown { return image }
                shown = state
                // Оставляем только активные слои, в исходном порядке; хук всегда сверху.
                root.sublayers = indices.compactMap { cache[$0]?.layer }
                for (item, opacity) in zip(timed, state.opacities) { item.layer.opacity = opacity }
                evict(excluding: Set(indices))
                guard state.opacities.contains(where: { $0 > 0 }) else {
                    image = nil
                    return nil
                }
                image = render()
                return image
            }
        }
    }

    private func makeEntry(index: Int) -> Entry {
        let plan: SubtitleLayerPlan
        if index == cues.count, let hook {
            plan = ShortsSubtitleRenderer.hookLayer(
                hook, renderSize: renderSize, appearance: appearance, duration: duration)
        } else {
            plan = ShortsSubtitleRenderer.captionLayer(
                for: cues[index], renderSize: renderSize, appearance: appearance,
                highlight: highlight, duration: duration)
        }
        for item in plan.timed { item.layer.removeAllAnimations() }
        return Entry(layer: plan.layer, timed: plan.timed, cost: plan.rasterBytes, access: access)
    }

    private func evict(excluding active: Set<Int>) {
        guard cacheCost > cacheCostLimit else { return }
        // Если сама сцена больше лимита, удаляем все неактивные записи.
        for (index, entry) in cache.sorted(by: { $0.value.access < $1.value.access }) {
            guard cacheCost > cacheCostLimit else { break }
            guard !active.contains(index) else { continue }
            cacheCost -= entry.cost
            cache[index] = nil
        }
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
