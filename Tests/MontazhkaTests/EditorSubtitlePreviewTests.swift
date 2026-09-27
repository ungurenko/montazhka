import Foundation
import Testing

@testable import MontazhkaKit

@Suite
struct EditorSubtitlePreviewTests {
    private let cues = [
        ShortsSubtitleCue(
            words: [
                ShortsSubtitleWord(text: "Привет", start: 1.0, end: 1.4),
                ShortsSubtitleWord(text: "всем", start: 1.6, end: 2.0),
            ],
            start: 1.0, end: 2.0),
        ShortsSubtitleCue(
            words: [ShortsSubtitleWord(text: "Начнём", start: 2.0, end: 2.6)],
            start: 2.0, end: 3.0),
    ]

    @Test
    func showsThePhraseSoundingNowLikeTheBurnedFile() {
        let appearance = ShortsSubtitleAppearance.default

        let first = EditorSubtitlePreview.overlay(at: 1.7, cues: cues, appearance: appearance, highlight: true)
        #expect(first == ShortsSubtitleOverlay(words: ["Привет", "всем"], appearance: appearance, activeWordIndex: 1))

        let atBoundary = EditorSubtitlePreview.overlay(at: 2.0, cues: cues, appearance: appearance, highlight: true)
        #expect(atBoundary?.words == ["Начнём"])

        let pause = EditorSubtitlePreview.overlay(at: 1.5, cues: cues, appearance: appearance, highlight: true)
        #expect(pause?.activeWordIndex == nil)

        #expect(
            EditorSubtitlePreview.overlay(at: 1.2, cues: cues, appearance: appearance, highlight: false)?
                .activeWordIndex == nil)
        #expect(EditorSubtitlePreview.overlay(at: 0.5, cues: cues, appearance: appearance, highlight: true) == nil)
        #expect(EditorSubtitlePreview.overlay(at: 3.0, cues: cues, appearance: appearance, highlight: true) == nil)
    }
}
