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
            let text = Text(subtitle.text)
                .font(.system(size: fontSize, weight: .bold))
                .foregroundStyle(foregroundColor)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: canvasSize.width * 0.88)
                .padding(.horizontal, fontSize * 0.45)
                .padding(.vertical, fontSize * 0.20)

            text
                .background {
                    if subtitle.style == .boxed {
                        RoundedRectangle(cornerRadius: fontSize * 0.28)
                            .fill(Color.black.opacity(0.72))
                    }
                }
                .shadow(
                    color: subtitle.style == .boxed ? .clear : .black.opacity(0.95),
                    radius: subtitle.style == .boxed ? 0 : fontSize * 0.10,
                    x: 0,
                    y: -fontSize * 0.04
                )
                .padding(.bottom, max(fontSize * 1.25, canvasSize.height * 0.085))
                .frame(width: canvasSize.width, height: canvasSize.height, alignment: .bottom)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .allowsHitTesting(false)
    }

    private var foregroundColor: Color {
        subtitle.style == .accent ? .yellow : .white
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
