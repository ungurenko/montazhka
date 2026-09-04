import CoreGraphics
import Testing

@testable import MontazhkaKit

@Suite
struct ShortsVideoCompositionTests {
    @Test
    func settingsProduceOnlyValidFrameRequests() {
        #expect(ShortsFrameSettings().previewRequest == .original)
        #expect(
            ShortsFrameSettings(mode: .verticalCrop, canvasColor: .white).exportRequest(quality: .high)
                == .verticalCrop)
        #expect(
            ShortsFrameSettings(mode: .verticalFit, canvasColor: .white).previewRequest
                == .verticalFit(color: .white, resolution: .source))
        #expect(
            ShortsFrameSettings(mode: .verticalFit, canvasColor: .black).exportRequest(quality: .compact)
                == .verticalFit(color: .black, resolution: .quality(.compact)))
    }

    @Test
    func subtitlePreviewFitsFrameIntoViewingArea() {
        // Вертикальный кадр в широкой области: подпись считается по узкой
        // картинке, а не по всей чёрной подложке.
        let vertical = ShortsSubtitlePreviewLayout.canvasSize(
            frameSize: CGSize(width: 1080, height: 1920),
            containerSize: CGSize(width: 900, height: 600))
        #expect(vertical == CGSize(width: 337.5, height: 600))

        let horizontal = ShortsSubtitlePreviewLayout.canvasSize(
            frameSize: CGSize(width: 1920, height: 1080),
            containerSize: CGSize(width: 600, height: 900))
        #expect(horizontal == CGSize(width: 600, height: 337.5))

        // Размер кадра ещё не известен — занимаем всю область, как раньше.
        let unknown = ShortsSubtitlePreviewLayout.canvasSize(
            frameSize: nil,
            containerSize: CGSize(width: 900, height: 600))
        #expect(unknown == CGSize(width: 900, height: 600))
    }

    @Test
    func fullHDLandscapeFitsInsideStandardVerticalCanvas() {
        let layout = ShortsFrameLayout.verticalFit(
            displaySize: CGSize(width: 1920, height: 1080),
            renderSize: CGSize(width: 1080, height: 1920))

        #expect(layout.renderSize == CGSize(width: 1080, height: 1920))
        #expect(abs(layout.contentRect.origin.x) < 0.001)
        #expect(abs(layout.contentRect.origin.y - 656.25) < 0.001)
        #expect(abs(layout.contentRect.width - 1080) < 0.001)
        #expect(abs(layout.contentRect.height - 607.5) < 0.001)
    }

    @Test
    func compactLandscapeFitsInside720By1280Canvas() {
        let layout = ShortsFrameLayout.verticalFit(
            displaySize: CGSize(width: 1920, height: 1080),
            renderSize: CGSize(width: 720, height: 1280))

        #expect(layout.renderSize == CGSize(width: 720, height: 1280))
        #expect(layout.contentRect == CGRect(x: 0, y: 437.5, width: 720, height: 405))
    }

    @Test
    func verticalSourceFitsWithoutCroppingAndOddCanvasBecomesEven() {
        let layout = ShortsFrameLayout.verticalFit(
            displaySize: CGSize(width: 1080, height: 1350),
            renderSize: CGSize(width: 1079, height: 1919))

        #expect(layout.renderSize == CGSize(width: 1080, height: 1920))
        #expect(layout.contentRect == CGRect(x: 0, y: 285, width: 1080, height: 1350))
    }

    @Test
    func qualityProducesExpectedVerticalCanvasWithoutUpscalingSmallSources() {
        let fullHD = CGSize(width: 1920, height: 1080)
        let small = CGSize(width: 640, height: 360)
        let odd = ShortsFrameLayout.verticalCanvasSize(
            for: CGSize(width: 1279, height: 717), quality: nil)

        #expect(
            ShortsFrameLayout.verticalCanvasSize(for: fullHD, quality: .high)
                == CGSize(width: 1080, height: 1920))
        #expect(
            ShortsFrameLayout.verticalCanvasSize(for: fullHD, quality: .compact)
                == CGSize(width: 720, height: 1280))
        #expect(
            ShortsFrameLayout.verticalCanvasSize(for: small, quality: .high)
                == CGSize(width: 360, height: 640))
        #expect(odd.height * 9 == odd.width * 16)
        #expect(odd.width <= 717 && Int(odd.width) % 2 == 0 && Int(odd.height) % 2 == 0)
    }
}
