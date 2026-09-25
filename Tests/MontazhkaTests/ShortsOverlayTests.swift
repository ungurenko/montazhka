@preconcurrency import AVFoundation
import Foundation
import Testing

@testable import MontazhkaKit

@Suite("Shorts hook and draft subtitles")
struct ShortsOverlayTests {
    private let clipA = UUID()
    private let clipB = UUID()

    private func word(_ text: String, _ start: Double, _ end: Double, clip: UUID) -> MappedTranscriptWord {
        MappedTranscriptWord(
            wordID: UUID().uuidString, text: text, clipID: clip, sourceID: UUID(),
            sourceStart: start, sourceEnd: end, timelineStart: start, timelineEnd: end, confidence: 1)
    }

    @Test("a phrase never runs across a cut, even after clips were moved")
    func cuesBreakAtClipChange() {
        let words = [
            word("раз", 0.0, 0.3, clip: clipA), word("два", 0.35, 0.6, clip: clipA),
            word("три", 0.65, 0.9, clip: clipB),
        ]
        let cues = ShortsSubtitleCueBuilder.make(mapped: words, notBefore: 0)
        #expect(cues.map(\.text) == ["раз два", "три"])
        #expect(cues[1].start == 0.65)
    }

    @Test("subtitles start only after the hook is gone")
    func cuesWaitForHook() {
        let words = [word("хук", 1.0, 1.4, clip: clipA), word("потом", 2.6, 3.0, clip: clipA)]
        let cues = ShortsSubtitleCueBuilder.make(mapped: words, notBefore: 2.5)
        #expect(cues.map(\.text) == ["потом"])
    }

    private func canvasComposition() -> AVMutableVideoComposition {
        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: 360, height: 640)
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        return composition
    }

    @Test("a hook alone is enough to draw overlays")
    func hookWithoutSubtitles() {
        let result = ShortsSubtitleRenderer.applying(
            canvasComposition(), cues: [], appearance: .default, highlight: false, duration: 10,
            hook: ShortsHook(text: "Монтаж за минуту"))
        #expect(result.animationTool != nil)
    }

    // Пиксели текста проверяет самопроверка приложения (ShortsSubtitleSelfTest):
    // в процессе юнит-тестов CoreText не рисует глифы.
    @Test("a still of the overlays has the size of the canvas")
    func snapshotSize() throws {
        let image = try #require(
            ShortsOverlaySnapshot.image(
                at: 1, renderSize: CGSize(width: 360, height: 640), cues: [], appearance: .default,
                highlight: false, hook: ShortsHook(text: "Монтаж за минуту")))
        #expect(image.width == 360 && image.height == 640)
    }
}
