import AppKit
import CoreText
import QuartzCore

/// Готовая фраза: слои, их времена и растры известны фабрике без обхода CALayer и приведения типов.
struct SubtitleLayerPlan {
    struct Timed {
        let layer: CALayer
        let from: Double
        let to: Double
        let fade: Double

        func opacity(at time: Double) -> Float {
            guard time >= from, time < to else { return 0 }
            guard fade > 0, time > to - fade else { return 1 }
            return Float(max(0, (to - time) / fade))
        }
    }

    let layer: CALayer
    let timed: [Timed]
    let rasters: [CGImage]

    /// Картинка подсветки общая для всех слов: её память учитывается один раз.
    var rasterBytes: Int {
        var seen = Set<ObjectIdentifier>()
        return rasters.reduce(0) { bytes, image in
            bytes + (seen.insert(ObjectIdentifier(image)).inserted ? image.bytesPerRow * image.height : 0)
        }
    }
}

/// Слой надписей (хук и фразы) для записи MP4 и снимков — см. `OverlayFrameRenderer`.
enum ShortsSubtitleRenderer {
    /// Все надписи ролика одним слоем: эталон проверок выбирает видимые по метаданным.
    static func overlayLayer(
        renderSize: CGSize,
        cues: [ShortsSubtitleCue],
        appearance: ShortsSubtitleAppearance,
        highlight: Bool,
        hook: ShortsHook?
    ) -> CALayer {
        let overlay = CALayer()
        overlay.frame = CGRect(origin: .zero, size: renderSize)
        for cue in cues {
            overlay.addSublayer(
                captionLayer(
                    for: cue,
                    renderSize: renderSize,
                    appearance: appearance,
                    highlight: highlight
                ).layer)
        }
        if let hook, !hook.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            overlay.addSublayer(
                hookLayer(hook, renderSize: renderSize, appearance: appearance).layer)
        }
        return overlay
    }

    /// Хук: крупно, сверху, в фирменном стиле субтитров; плавно гаснет.
    static func hookLayer(
        _ hook: ShortsHook,
        renderSize: CGSize,
        appearance: ShortsSubtitleAppearance
    ) -> SubtitleLayerPlan {
        let text = hook.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var fontSize = appearance.baseFontSize(canvasSize: renderSize) * hookScale
        let maxTextWidth = { ShortsSubtitleLayout.textWidth(fontSize: fontSize, canvasSize: renderSize) }
        var font = appearance.font.font(ofSize: fontSize)
        for _ in 0...4 where ShortsSubtitleTextWrapper.wrap(text, font: font, maxWidth: maxTextWidth()).lineCount > 3 {
            fontSize *= 0.88
            font = appearance.font.font(ofSize: fontSize)
        }
        let textLayout = ShortsSubtitleTextWrapper.wrap(text, font: font, maxWidth: maxTextWidth())
        let verticalPadding = fontSize * ShortsSubtitleLayout.verticalPaddingScale
        let height =
            ShortsSubtitleLayout.lineHeight(for: font) * CGFloat(textLayout.lineCount)
            + verticalPadding * 2
        let width = renderSize.width * ShortsSubtitleLayout.widthRatio(for: renderSize)
        let frame = CGRect(
            x: (renderSize.width - width) / 2,
            y: renderSize.height * (1 - hookTopRatio) - height,
            width: width, height: height)
        var style = appearance
        if style.background == .none { style.background = .shadow }
        let block = textBlock(textLayout, font: font, appearance: style, frame: frame)
        let timed = visibilityWindow(
            to: block.container, start: 0, end: hook.duration, fadeOut: 0.3)
        return SubtitleLayerPlan(layer: block.container, timed: [timed], rasters: block.image.map { [$0] } ?? [])
    }

    /// Хук крупнее субтитров во столько раз.
    static let hookScale: CGFloat = 1.7
    /// Верхний край хука — эта доля высоты кадра от верха.
    static let hookTopRatio: CGFloat = 0.05

    /// Подложка и текст одной надписи в заданной рамке. Общая часть хука и фраз.
    private static func textBlock(
        _ textLayout: ShortsSubtitleTextLayout,
        font: NSFont,
        appearance: ShortsSubtitleAppearance,
        frame: CGRect
    ) -> (container: CALayer, textLayer: CALayer, textFrame: CGRect, image: CGImage?) {
        let fontSize = font.pointSize
        let container = CALayer()
        container.frame = frame
        container.masksToBounds = false
        container.opacity = 0
        container.contentsScale = 2

        let textFrame = container.bounds.insetBy(
            dx: fontSize * ShortsSubtitleLayout.horizontalPaddingScale,
            dy: fontSize * ShortsSubtitleLayout.verticalPaddingScale)
        let textLayer = CALayer()
        textLayer.frame = textFrame
        textLayer.contentsScale = 2
        let image = makeTextImage(
            textLayout.text,
            font: font,
            color: appearance.textColor.nsColor,
            outlineWidth: appearance.background == .outline
                ? fontSize * ShortsSubtitleLayout.outlineWidthScale : 0,
            size: textLayer.bounds.size)
        textLayer.contents = image

        switch appearance.background {
        case .plate:
            container.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
            container.cornerRadius = fontSize * ShortsSubtitleLayout.cornerRadiusScale
        case .shadow:
            textLayer.shadowColor = NSColor.black.cgColor
            textLayer.shadowOpacity = 0.95
            textLayer.shadowRadius = fontSize * ShortsSubtitleLayout.shadowRadiusScale
            textLayer.shadowOffset = CGSize(
                width: 0, height: -fontSize * ShortsSubtitleLayout.shadowOffsetScale)
        case .outline, .none:
            break
        }

        container.addSublayer(textLayer)
        return (container, textLayer, textFrame, image)
    }

    static func captionLayer(
        for cue: ShortsSubtitleCue,
        renderSize: CGSize,
        appearance: ShortsSubtitleAppearance,
        highlight: Bool
    ) -> SubtitleLayerPlan {
        let font = ShortsSubtitleLayout.fittingFont(
            text: cue.text, appearance: appearance, canvasSize: renderSize)
        let fontSize = font.pointSize
        let verticalPadding = fontSize * ShortsSubtitleLayout.verticalPaddingScale
        let width = renderSize.width * ShortsSubtitleLayout.widthRatio(for: renderSize)
        let maxTextWidth = ShortsSubtitleLayout.textWidth(
            fontSize: fontSize, canvasSize: renderSize)
        let textLayout = ShortsSubtitleTextWrapper.wrap(
            cue.text, font: font, maxWidth: maxTextWidth)
        let lineHeight = ShortsSubtitleLayout.lineHeight(for: font)
        let height = lineHeight * CGFloat(textLayout.lineCount) + verticalPadding * 2
        let bottomMargin = ShortsSubtitleLayout.bottomMargin(
            appearance: appearance, canvasSize: renderSize)

        let block = textBlock(
            textLayout, font: font, appearance: appearance,
            frame: CGRect(x: (renderSize.width - width) / 2, y: bottomMargin, width: width, height: height))
        let container = block.container
        let textFrame = block.textFrame
        var timed: [SubtitleLayerPlan.Timed] = []
        var rasters = block.image.map { [$0] } ?? []

        // Звучащее слово перекрашивается: поверх кладётся кусок той же фразы,
        // отрисованной вторым цветом, обрезанный по слову через contentsRect.
        // На фразу приходится ровно одна дополнительная картинка — минутный
        // ролик с картинкой на каждое слово стоил бы сотни мегабайт.
        if highlight,
            let highlighted = makeTextImage(
                textLayout.text,
                font: font,
                color: appearance.highlightColor.nsColor,
                outlineWidth: appearance.background == .outline
                    ? fontSize * ShortsSubtitleLayout.outlineWidthScale : 0,
                size: block.textLayer.bounds.size)
        {
            let overlay = CALayer()
            overlay.frame = textFrame
            let words = highlightedWordLayers(
                cue: cue, textLayout: textLayout, image: highlighted,
                bounds: CGRect(origin: .zero, size: textFrame.size),
                lineHeight: lineHeight, fontSize: fontSize)
            for word in words { overlay.addSublayer(word.layer) }
            timed.append(contentsOf: words)
            if !words.isEmpty { rasters.append(highlighted) }
            container.addSublayer(overlay)
        }
        let phrase = visibilityWindow(to: container, start: cue.start, end: cue.end)
        timed.insert(phrase, at: 0)
        return SubtitleLayerPlan(layer: container, timed: timed, rasters: rasters)
    }

    /// По слою на слово: тот же снимок фразы, обрезанный по рамке слова.
    /// Строки нумеруются сверху, а слой Core Animation растёт снизу вверх —
    /// отсюда переворот номера строки.
    private static func highlightedWordLayers(
        cue: ShortsSubtitleCue,
        textLayout: ShortsSubtitleTextLayout,
        image: CGImage,
        bounds: CGRect,
        lineHeight: CGFloat,
        fontSize: CGFloat
    ) -> [SubtitleLayerPlan.Timed] {
        guard bounds.width > 0, bounds.height > 0 else { return [] }
        let inset = fontSize * ShortsSubtitleLayout.highlightInsetScale

        return cue.words.indices.compactMap { index -> SubtitleLayerPlan.Timed? in
            guard textLayout.placements.indices.contains(index) else { return nil }
            let placement = textLayout.placements[index]
            guard textLayout.lineWidths.indices.contains(placement.line),
                placement.width > 0
            else { return nil }
            let lineWidth = textLayout.lineWidths[placement.line]
            let lineFromBottom = CGFloat(textLayout.lineCount - 1 - placement.line)
            let frame = CGRect(
                x: (bounds.width - lineWidth) / 2 + placement.x - inset,
                y: lineFromBottom * lineHeight,
                width: placement.width + inset * 2,
                height: lineHeight
            ).intersection(bounds)
            guard frame.width > 0, frame.height > 0 else { return nil }

            let layer = CALayer()
            layer.frame = frame
            layer.contents = image
            layer.contentsScale = 2
            layer.contentsRect = CGRect(
                x: frame.minX / bounds.width,
                y: frame.minY / bounds.height,
                width: frame.width / bounds.width,
                height: frame.height / bounds.height)
            layer.opacity = 0
            return visibilityWindow(to: layer, start: cue.words[index].start, end: cue.words[index].end)
        }
    }

    private static func makeTextImage(
        _ text: String,
        font: NSFont,
        color: NSColor,
        outlineWidth: CGFloat,
        size: CGSize
    ) -> CGImage? {
        let scale: CGFloat = 2
        let width = max(1, Int(ceil(size.width * scale)))
        let height = max(1, Int(ceil(size.height * scale)))
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        let scaledFont = CTFontCreateWithName(
            font.fontName as CFString, font.pointSize * scale, nil)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineBreakMode = .byWordWrapping
        var attributes: [NSAttributedString.Key: Any] = [
            .font: scaledFont,
            .foregroundColor: color.cgColor,
            .paragraphStyle: paragraphStyle,
        ]
        if outlineWidth > 0 {
            attributes[.strokeColor] = NSColor.black.cgColor
            // Отрицательная ширина в CoreText означает «обвести и залить»:
            // без минуса буквы остались бы пустыми внутри.
            attributes[.strokeWidth] = -outlineWidth * scale
        }
        let attributedText = NSAttributedString(string: text, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(attributedText)
        // Рамка по высоте самого текста, по центру картинки: строка, не
        // влезшая в рамку, CoreText не рисует вовсе — лучше чуть выйти за край.
        let textHeight = ceil(
            CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter, CFRange(location: 0, length: attributedText.length), nil,
                CGSize(width: CGFloat(width), height: .greatestFiniteMagnitude), nil
            ).height)
        let frameHeight = max(CGFloat(height), textHeight)
        let path = CGPath(
            rect: CGRect(x: 0, y: (CGFloat(height) - frameHeight) / 2, width: CGFloat(width), height: frameHeight),
            transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: attributedText.length),
            path,
            nil)

        context.clear(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        CTFrameDraw(frame, context)
        return context.makeImage()
    }

    /// Ключи, под которыми слой помнит своё окно видимости: по ним
    /// неподвижный снимок решает, что показать, без проигрывания анимации.
    static let visibleFromKey = "montazhkaVisibleFrom"
    static let visibleToKey = "montazhkaVisibleTo"
    /// Сколько секунд слой затухает к концу окна; нет ключа — гаснет сразу.
    static let visibleFadeKey = "montazhkaVisibleFade"

    private static func visibilityWindow(
        to layer: CALayer,
        start visibleFrom: Double,
        end visibleTo: Double,
        fadeOut: Double = 0
    ) -> SubtitleLayerPlan.Timed {
        layer.setValue(visibleFrom, forKey: visibleFromKey)
        layer.setValue(visibleTo, forKey: visibleToKey)
        if fadeOut > 0 { layer.setValue(fadeOut, forKey: visibleFadeKey) }
        return SubtitleLayerPlan.Timed(layer: layer, from: visibleFrom, to: visibleTo, fade: fadeOut)
    }
}
