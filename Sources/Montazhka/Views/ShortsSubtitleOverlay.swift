import SwiftUI

/// Текстовый слой preview. AVPlayer не запекает Core Animation tool, поэтому
/// предпросмотр и финальный offline-рендер используют одну модель, но разные
/// поверхности отображения.
struct ShortsSubtitleOverlayView: View {
    let subtitle: ShortsSubtitleOverlay
    /// Размер кадра, который собирает видеокомпозиция просмотра. Именно он, а не
    /// размер, о котором отчитывается видеослой: тот приходит с задержкой, и
    /// подпись успевала расползтись на всю чёрную область.
    let frameSize: CGSize?

    var body: some View {
        GeometryReader { proxy in
            let canvasSize = ShortsSubtitlePreviewLayout.canvasSize(
                frameSize: frameSize,
                containerSize: proxy.size)
            let font = ShortsSubtitleLayout.fittingFont(
                text: subtitle.text,
                appearance: subtitle.appearance,
                canvasSize: canvasSize)
            let fontSize = font.pointSize
            let text = Text(attributedText)
                .font(Font(font))
                .multilineTextAlignment(.center)
                .lineLimit(ShortsSubtitleLayout.maxLines)
                .fixedSize(horizontal: false, vertical: true)
                .frame(
                    maxWidth: ShortsSubtitleLayout.textWidth(
                        fontSize: fontSize, canvasSize: canvasSize)
                )
                .padding(.horizontal, fontSize * ShortsSubtitleLayout.horizontalPaddingScale)
                .padding(.vertical, fontSize * ShortsSubtitleLayout.verticalPaddingScale)

            text
                .background {
                    if subtitle.appearance.background == .plate {
                        RoundedRectangle(
                            cornerRadius: fontSize * ShortsSubtitleLayout.cornerRadiusScale
                        )
                        .fill(Color.black.opacity(0.72))
                    }
                }
                .shadow(
                    color: subtitle.appearance.background == .shadow
                        ? .black.opacity(0.95) : .clear,
                    radius: subtitle.appearance.background == .shadow
                        ? fontSize * ShortsSubtitleLayout.shadowRadiusScale : 0,
                    x: 0,
                    y: subtitle.appearance.background == .shadow
                        ? -fontSize * ShortsSubtitleLayout.shadowOffsetScale : 0
                )
                .padding(
                    .bottom,
                    ShortsSubtitleLayout.bottomMargin(
                        appearance: subtitle.appearance,
                        canvasSize: canvasSize)
                )
                .frame(width: canvasSize.width, height: canvasSize.height, alignment: .bottom)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .allowsHitTesting(false)
    }

    /// Звучащее слово перекрашивается — так же, как в запечённых субтитрах.
    private var attributedText: AttributedString {
        let base = Color(subtitle.appearance.textColor.nsColor)
        let highlighted = Color(subtitle.appearance.highlightColor.nsColor)
        var result = AttributedString()
        for (index, word) in subtitle.words.enumerated() {
            var piece = AttributedString(word)
            piece.foregroundColor = index == subtitle.activeWordIndex ? highlighted : base
            if subtitle.appearance.background == .outline {
                piece.strokeColor = .black
                // В атрибутах текста ширина обводки задаётся в процентах от
                // размера шрифта, минус означает «обвести и залить».
                piece.strokeWidth = -ShortsSubtitleLayout.outlineWidthScale * 100
            }
            if index > 0 { result += AttributedString(" ") }
            result += piece
        }
        return result
    }
}

enum ShortsSubtitlePreviewLayout {
    /// Кадр вписан в область просмотра по своим пропорциям — ровно так же, как
    /// его показывает `AVPlayerLayer` с `videoGravity = .resizeAspect`.
    static func canvasSize(frameSize: CGSize?, containerSize: CGSize) -> CGSize {
        guard let frameSize,
            frameSize.width > 0, frameSize.height > 0,
            containerSize.width > 0, containerSize.height > 0
        else { return containerSize }
        let scale = min(
            containerSize.width / frameSize.width,
            containerSize.height / frameSize.height)
        return CGSize(width: frameSize.width * scale, height: frameSize.height * scale)
    }
}
