import SwiftUI

/// Текстовый слой preview. AVPlayer не запекает Core Animation tool, поэтому
/// предпросмотр и финальный offline-рендер используют одну модель, но разные
/// поверхности отображения.
struct ShortsSubtitleOverlayView: View {
    let subtitle: ShortsSubtitleOverlay
    let presentationSize: CGSize

    var body: some View {
        GeometryReader { proxy in
            let canvasSize = ShortsSubtitlePreviewLayout.canvasSize(
                reportedVideoSize: presentationSize,
                containerSize: proxy.size)
            let fontSize = max(
                14, min(canvasSize.width, canvasSize.height) * subtitle.size.scale)
            let text = Text(attributedText)
                .font(.system(size: fontSize, weight: .bold))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: canvasSize.width * ShortsSubtitleLayout.widthRatio)
                .padding(.horizontal, fontSize * ShortsSubtitleLayout.horizontalPaddingScale)
                .padding(.vertical, fontSize * ShortsSubtitleLayout.verticalPaddingScale)

            text
                .background {
                    if subtitle.style == .boxed {
                        RoundedRectangle(
                            cornerRadius: fontSize * ShortsSubtitleLayout.cornerRadiusScale
                        )
                        .fill(Color.black.opacity(0.72))
                    }
                }
                .shadow(
                    color: subtitle.style == .boxed ? .clear : .black.opacity(0.95),
                    radius: subtitle.style == .boxed
                        ? 0 : fontSize * ShortsSubtitleLayout.shadowRadiusScale,
                    x: 0,
                    y: -fontSize * ShortsSubtitleLayout.shadowOffsetScale
                )
                .padding(
                    .bottom,
                    ShortsSubtitleLayout.bottomMargin(
                        fontSize: fontSize,
                        canvasSize: canvasSize)
                )
                .frame(width: canvasSize.width, height: canvasSize.height, alignment: .bottom)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .allowsHitTesting(false)
    }

    /// Звучащее слово перекрашивается — так же, как в запечённых субтитрах.
    private var attributedText: AttributedString {
        let base = Color(ShortsSubtitleLayout.foregroundColor(for: subtitle.style))
        let highlighted = Color(ShortsSubtitleLayout.highlightColor(for: subtitle.style))
        var result = AttributedString()
        for (index, word) in subtitle.words.enumerated() {
            var piece = AttributedString(word)
            piece.foregroundColor = index == subtitle.activeWordIndex ? highlighted : base
            if index > 0 { result += AttributedString(" ") }
            result += piece
        }
        return result
    }
}

enum ShortsSubtitlePreviewLayout {
    static func canvasSize(reportedVideoSize: CGSize, containerSize: CGSize) -> CGSize {
        guard reportedVideoSize.width > 0, reportedVideoSize.height > 0 else {
            return containerSize
        }
        return CGSize(
            width: min(reportedVideoSize.width, containerSize.width),
            height: min(reportedVideoSize.height, containerSize.height))
    }
}
