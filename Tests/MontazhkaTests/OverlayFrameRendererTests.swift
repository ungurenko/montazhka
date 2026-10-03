import AppKit
import CoreGraphics
import Foundation
import QuartzCore

@testable import MontazhkaKit

#if !CAPTION_BENCHMARK
    import Testing
#endif

/// Frozen reference from a4e252e. Keep its eager layers and full opacity scan:
/// it protects pixels, visibility boundaries and arbitrary request ordering.
final class LegacyCaptionFrameRenderer {
    private struct Timed {
        let layer: CALayer
        let from: Double
        let to: Double
        let fade: Double
    }

    private let root: CALayer
    private let renderSize: CGSize
    private let timed: [Timed]
    private var shown: [Float]?
    private var image: CGImage?

    init?(
        renderSize: CGSize, cues: [ShortsSubtitleCue], appearance: ShortsSubtitleAppearance,
        highlight: Bool, hook: ShortsHook?
    ) {
        let hook = hook.flatMap { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        guard !cues.isEmpty || hook != nil, renderSize.width > 0, renderSize.height > 0 else { return nil }
        root = ShortsSubtitleRenderer.overlayLayer(
            renderSize: renderSize, cues: cues, appearance: appearance, highlight: highlight,
            hook: hook)
        self.renderSize = renderSize
        var timed: [Timed] = []
        Self.collect(root, into: &timed)
        self.timed = timed
    }

    func image(at time: Double) -> CGImage? {
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
        guard
            let context = CGContext(
                data: nil, width: Int(renderSize.width), height: Int(renderSize.height),
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        root.render(in: context)
        image = context.makeImage()
        return image
    }

    private static func opacity(of item: Timed, at time: Double) -> Double {
        guard time >= item.from, time < item.to else { return 0 }
        guard item.fade > 0, time > item.to - item.fade else { return 1 }
        return max(0, (item.to - time) / item.fade)
    }

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
}

enum CaptionGoldenFixture {
    struct Failure: Error { let reason: String }

    static func cue(_ text: String, from: Double, to: Double) -> ShortsSubtitleCue {
        let tokens = text.split(separator: " ").map(String.init)
        let step = (to - from) / Double(max(1, tokens.count))
        let words = tokens.enumerated().map { index, token in
            let start = from + Double(index) * step
            return ShortsSubtitleWord(text: token, start: start, end: start + step * 0.85)
        }
        return ShortsSubtitleCue(words: words, start: from, end: to)
    }

    static let overlappingCues = [
        cue("Вторая фраза рядом с первой", from: 0.7, to: 2.3),
        cue("Первая фраза с точной подсветкой", from: 0.2, to: 1.6),
        cue("После паузы снова виден текст", from: 3.0, to: 4.2),
    ]

    static let times: [Double] = [
        -0.1, 0, 0.199999, 0.2, 0.25, 0.437999, 0.438, 0.48,
        0.699999, 0.7, 1.0, 1.599999, 1.6, 1.7, 1.700001,
        1.8, 1.95, 1.999999, 2, 2.299999, 2.3, 2.5,
        2.999999, 3, 3.12, 4.199999, 4.2, 6,
        1.0, 1.0, 0.2, 4.2, 0, 3.4, 1.8,
    ]

    static func hourCues(count: Int = 720, seconds: Double = 3600) -> [ShortsSubtitleCue] {
        let step = seconds / Double(max(1, count))
        return (0..<count).map { index in
            let text = "Мы сейчас видим как идёт монтаж и все слова в кадре точно дают нам этап \(index)"
            return cue(text, from: Double(index) * step, to: (Double(index) + 1) * step - min(0.15, step / 10))
        }
    }

    /// Normalized premultiplied RGBA, including nil/transparent distinction.
    static func rgba(_ image: CGImage?) throws -> Data? {
        guard let image else { return nil }
        let row = image.width * 4
        guard
            let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: row, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            let data = context.data
        else { throw Failure(reason: "RGBA context unavailable") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: data, count: row * image.height)
    }
}

#if !CAPTION_BENCHMARK
    @Suite("Lazy caption frames match the eager reference", .serialized)
    struct OverlayFrameRendererTests {
        @Test(
            "pixels match at word and cue boundaries, overlaps, fades and arbitrary time ordering",
            arguments: [false, true])
        func pixelsMatchReference(highlight: Bool) throws {
            for size in [CGSize(width: 640, height: 360), CGSize(width: 360, height: 640)] {
                let hook = ShortsHook(text: "Хук поверх двух фраз", duration: 2)
                let renderer = try #require(
                    OverlayFrameRenderer(
                        renderSize: size, cues: CaptionGoldenFixture.overlappingCues, appearance: .default,
                        highlight: highlight, hook: hook))
                let reference = try #require(
                    LegacyCaptionFrameRenderer(
                        renderSize: size, cues: CaptionGoldenFixture.overlappingCues, appearance: .default,
                        highlight: highlight, hook: hook))
                let wordBoundaries = CaptionGoldenFixture.overlappingCues.flatMap { cue in
                    cue.words.flatMap { [$0.start - 0.000001, $0.start, $0.end - 0.000001, $0.end] }
                }
                for time in CaptionGoldenFixture.times + wordBoundaries {
                    try autoreleasepool {
                        let expected = try CaptionGoldenFixture.rgba(reference.image(at: time))
                        let actual = try CaptionGoldenFixture.rgba(renderer.image(at: time))
                        #expect(actual == expected, "time=\(time), size=\(size), highlight=\(highlight)")
                    }
                }
            }
        }

        @Test("a frozen final cue preserves the image and visibility outside its original window")
        func frozenTimeMatchesReference() throws {
            let cues = [CaptionGoldenFixture.cue("Последнее слово остаётся в кадре", from: 1, to: 2)]
            let renderer = try #require(
                OverlayFrameRenderer(
                    renderSize: CGSize(width: 640, height: 360), cues: cues, appearance: .default, highlight: true,
                    hook: nil))
            let reference = try #require(
                LegacyCaptionFrameRenderer(
                    renderSize: CGSize(width: 640, height: 360), cues: cues, appearance: .default, highlight: true,
                    hook: nil))
            let freezeAt = 1.97
            for time in [0, 1.0, 1.5, 1.97, 2, 3, 5, 1.2, 5, 5] {
                let frozen = min(time, freezeAt)
                let actual = try CaptionGoldenFixture.rgba(renderer.image(at: frozen))
                let expected = try CaptionGoldenFixture.rgba(reference.image(at: frozen))
                #expect(actual == expected)
            }
        }

        @Test("a long sequence and later revisits do not change caption pixels")
        func revisitingLongSequenceMatchesReference() throws {
            let cues = CaptionGoldenFixture.hourCues(count: 30, seconds: 150)
            let size = CGSize(width: 640, height: 360)
            let renderer = try #require(
                OverlayFrameRenderer(
                    renderSize: size, cues: cues, appearance: .default, highlight: true, hook: nil))
            let reference = try #require(
                LegacyCaptionFrameRenderer(
                    renderSize: size, cues: cues, appearance: .default, highlight: true, hook: nil))
            let forward = cues.map { $0.start + 0.2 }
            for time in forward + forward.reversed() + [0.2, 0.2, 145.2, 0.2] {
                try autoreleasepool {
                    let actual = try CaptionGoldenFixture.rgba(renderer.image(at: time))
                    let expected = try CaptionGoldenFixture.rgba(reference.image(at: time))
                    #expect(actual == expected, "time=\(time)")
                }
            }
        }

        @Test("zero or minimal raster caches preserve overlaps, fades and backwards revisits", arguments: [0, 1])
        func boundedCacheRevisitsMatchReference(cacheCostLimit: Int) throws {
            let cues =
                CaptionGoldenFixture.hourCues(count: 12, seconds: 60)
                + CaptionGoldenFixture.overlappingCues
            let size = CGSize(width: 640, height: 360)
            let hook = ShortsHook(text: "Хук поверх двух фраз", duration: 2)
            let renderer = try #require(
                OverlayFrameRenderer(
                    renderSize: size, cues: cues, appearance: .default, highlight: true, hook: hook,
                    cacheCostLimit: cacheCostLimit))
            let reference = try #require(
                LegacyCaptionFrameRenderer(
                    renderSize: size, cues: cues, appearance: .default, highlight: true, hook: hook))
            let forward = cues.prefix(12).map { $0.start + 0.2 }
            for time in CaptionGoldenFixture.times + forward + forward.reversed() + [0.2, 0.2, 55.2, 1.8] {
                try autoreleasepool {
                    let actual = try CaptionGoldenFixture.rgba(renderer.image(at: time))
                    let expected = try CaptionGoldenFixture.rgba(reference.image(at: time))
                    #expect(actual == expected, "time=\(time), cacheCostLimit=\(cacheCostLimit)")
                }
            }
        }

        @Test("active rasters survive a zero budget and are released after all cues finish")
        func zeroBudgetReleasesInactiveRasters() throws {
            let size = CGSize(width: 640, height: 360)
            let cues = [CaptionGoldenFixture.cue("Активная надпись остаётся видимой", from: 0, to: 2)]
            let renderer = try #require(
                OverlayFrameRenderer(
                    renderSize: size, cues: cues, appearance: .default, highlight: true, hook: nil,
                    cacheCostLimit: 0))
            let reference = try #require(
                LegacyCaptionFrameRenderer(
                    renderSize: size, cues: cues, appearance: .default, highlight: true, hook: nil))
            let active = try #require(renderer.image(at: 0.3))
            let actual = try CaptionGoldenFixture.rgba(active)
            let expected = try CaptionGoldenFixture.rgba(reference.image(at: 0.3))
            #expect(actual == expected)
            #expect(renderer.cachedImageBytes > 0)
            #expect(renderer.image(at: 1000) == nil)
            #expect(renderer.cachedImageBytes == 0)
            let revisited = try CaptionGoldenFixture.rgba(renderer.image(at: 0.3))
            #expect(revisited == expected)
        }

        @Test("words outlasting their cue preserve transparent images and the nil boundary")
        func wordsOutlastingCuePreserveTransparentImage() throws {
            let cues = [
                ShortsSubtitleCue(
                    words: [
                        ShortsSubtitleWord(text: "Перекрытие", start: 0, end: 3),
                        ShortsSubtitleWord(text: "речи", start: 1, end: 1.5),
                    ], start: 0, end: 1.5)
            ]
            let size = CGSize(width: 640, height: 360)
            let renderer = try #require(
                OverlayFrameRenderer(
                    renderSize: size, cues: cues, appearance: .default, highlight: true, hook: nil,
                    cacheCostLimit: 0))
            let reference = try #require(
                LegacyCaptionFrameRenderer(
                    renderSize: size, cues: cues, appearance: .default, highlight: true, hook: nil))
            for time in [1.49, 1.5, 2.0, 2.9, 3.0, 2.0, 1.2] {
                let actual = try CaptionGoldenFixture.rgba(renderer.image(at: time))
                let expected = try CaptionGoldenFixture.rgba(reference.image(at: time))
                #expect(actual == expected, "time=\(time)")
                if time == 2 {
                    let transparent = try #require(actual)
                    #expect(transparent.allSatisfy { $0 == 0 })
                }
            }
        }

        @Test("blank hooks and empty caption lists keep the original nil contract")
        func emptyRendererContract() {
            #expect(
                OverlayFrameRenderer(
                    renderSize: CGSize(width: 640, height: 360), cues: [], appearance: .default,
                    highlight: true, hook: ShortsHook(text: "  \n")) == nil)
            #expect(
                OverlayFrameRenderer(
                    renderSize: .zero, cues: CaptionGoldenFixture.overlappingCues, appearance: .default,
                    highlight: true, hook: nil) == nil)
        }
    }
#endif
