@preconcurrency import AVFoundation
import AppKit
import CoreText
import Foundation
import QuartzCore

/// Визуальный стиль автоматических субтитров.
enum ShortsSubtitleStyle: String, CaseIterable, Identifiable, Sendable {
    case classic
    case accent
    case boxed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: return "Классика"
        case .accent: return "Акцент"
        case .boxed: return "Подложка"
        }
    }
}

/// Размер текста субтитров. Масштаб считается от короткой стороны кадра,
/// поэтому надпись остаётся читаемой и в горизонтальном, и в вертикальном видео.
enum ShortsSubtitleSize: String, CaseIterable, Identifiable, Sendable {
    case small
    case medium
    case large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: return "Маленький"
        case .medium: return "Средний"
        case .large: return "Крупный"
        }
    }

    var scale: CGFloat {
        switch self {
        case .small: return 0.045
        case .medium: return 0.060
        case .large: return 0.075
        }
    }
}

/// Настройки, которые выбираются в интерфейсе shorts и сохраняются между запусками.
struct ShortsSubtitleSettings: Equatable, Sendable {
    var enabled: Bool
    var style: ShortsSubtitleStyle
    var size: ShortsSubtitleSize
    /// Подсветка звучащего слова — стандарт коротких роликов.
    var highlightActiveWord: Bool

    static let `default` = ShortsSubtitleSettings(
        enabled: false, style: .classic, size: .medium, highlightActiveWord: true)

    static func saved(
        in store: any PreferenceStoring = UserDefaultsPreferenceStore.standard
    ) -> ShortsSubtitleSettings {
        let style =
            ShortsSubtitleStyle(
                rawValue: store.string(forKey: Keys.style) ?? "") ?? .classic
        let size =
            ShortsSubtitleSize(
                rawValue: store.string(forKey: Keys.size) ?? "") ?? .medium
        let enabled = store.bool(forKey: Keys.enabled)
        // Строкой, а не флагом: отсутствие ключа надо отличать от «выключено»,
        // потому что подсветка включена по умолчанию.
        let highlight = store.string(forKey: Keys.highlight).map { $0 == "on" } ?? true
        return ShortsSubtitleSettings(
            enabled: enabled, style: style, size: size, highlightActiveWord: highlight)
    }

    func save(in store: any PreferenceStoring = UserDefaultsPreferenceStore.standard) {
        store.set(enabled, forKey: Keys.enabled)
        store.set(style.rawValue, forKey: Keys.style)
        store.set(size.rawValue, forKey: Keys.size)
        store.set(highlightActiveWord ? "on" : "off", forKey: Keys.highlight)
    }

    func mode(with words: [TranscriptWord]) -> ShortsSubtitleMode {
        guard enabled, !words.isEmpty else { return .off }
        return .on(words: words, style: style, size: size, highlight: highlightActiveWord)
    }

    private enum Keys {
        static let enabled = "shorts.subtitlesEnabled"
        static let style = "shorts.subtitleStyle"
        static let size = "shorts.subtitleSize"
        static let highlight = "shorts.subtitleHighlight"
    }
}

/// Данные для одного рендера. Слова входят в режим вместе с настройками,
/// поэтому exporter не может получить «включённые» субтитры отдельным флагом
/// и забыть передать их текст.
enum ShortsSubtitleMode: Equatable, Sendable {
    case off
    case on(
        words: [TranscriptWord], style: ShortsSubtitleStyle,
        size: ShortsSubtitleSize, highlight: Bool)
}

/// Одно слово фразы. Время уже приведено к шкале готового ролика.
struct ShortsSubtitleWord: Equatable, Sendable {
    let text: String
    let start: Double
    let end: Double
}

/// Одна фраза, которая показывается в заданном диапазоне времени.
/// Время уже приведено к шкале конкретного предпросмотра или экспорта.
struct ShortsSubtitleCue: Equatable, Sendable {
    let words: [ShortsSubtitleWord]
    let start: Double
    let end: Double

    var text: String { words.map(\.text).joined(separator: " ") }

    /// Какое слово звучит в этот момент. nil — пауза между словами фразы.
    func activeWordIndex(at time: Double) -> Int? {
        words.firstIndex { time >= $0.start && time < $0.end }
    }
}

/// Данные для текстового слоя поверх AVPlayer. Preview рисует этот слой в UI,
/// потому что AVVideoCompositionCoreAnimationTool предназначен для offline-рендера.
struct ShortsSubtitleOverlay: Equatable, Sendable {
    let words: [String]
    let style: ShortsSubtitleStyle
    let size: ShortsSubtitleSize
    /// Какое слово подсвечено. nil — подсветка выключена или звучит пауза.
    let activeWordIndex: Int?

    var text: String { words.joined(separator: " ") }
}

enum ShortsSubtitleOverlayBuilder {
    static func make(
        at time: Double,
        timeMap: ShortsTimeMap,
        mode: ShortsSubtitleMode
    ) -> ShortsSubtitleOverlay? {
        guard case let .on(words, style, size, highlight) = mode else { return nil }
        let cues = ShortsSubtitleCueBuilder.make(words: words, timeMap: timeMap)
        guard let cue = cues.first(where: { time >= $0.start && time < $0.end }) else {
            return nil
        }
        return ShortsSubtitleOverlay(
            words: cue.words.map(\.text), style: style, size: size,
            activeWordIndex: highlight ? cue.activeWordIndex(at: time) : nil)
    }
}

/// Делит слова локальной расшифровки на короткие читаемые фразы.
/// Это отдельная чистая логика: её можно проверять без запуска AVFoundation.
enum ShortsSubtitleCueBuilder {
    private static let maxWords = 4
    private static let maxCharacters = 34
    private static let maxDuration = 1.85
    private static let maxGap = 0.50

    /// Слова приводятся к шкале готового ролика через карту времени: то, что
    /// попало в вырезанную паузу, исчезает вместе с ней.
    static func make(words: [TranscriptWord], timeMap: ShortsTimeMap) -> [ShortsSubtitleCue] {
        guard timeMap.outputDuration > 0 else { return [] }

        struct Placed {
            let word: ShortsSubtitleWord
            let segment: Int
        }

        // Сначала отсекаем всё за пределами ролика: превью строит фразы на
        // каждом кадре, а транскрипт часового видео — это тысячи слов.
        let placed: [Placed] =
            words
            .filter { $0.end > timeMap.sourceStart && $0.start < timeMap.sourceEnd }
            .sorted { left, right in
                if left.start != right.start { return left.start < right.start }
                return left.end < right.end
            }
            .compactMap { word -> Placed? in
                let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty,
                    let piece = timeMap.longestVisiblePiece(from: word.start, to: word.end),
                    let start = timeMap.outputTime(forSource: piece.start),
                    let end = timeMap.outputTime(forSource: piece.end),
                    let segment = timeMap.segments.firstIndex(where: {
                        piece.start >= $0.start && piece.end <= $0.end
                    }),
                    end > start
                else { return nil }
                return Placed(
                    word: ShortsSubtitleWord(text: text, start: start, end: end),
                    segment: segment)
            }

        guard !placed.isEmpty else { return [] }

        var cues: [ShortsSubtitleCue] = []
        var current: [ShortsSubtitleWord] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            cues.append(
                ShortsSubtitleCue(
                    words: current,
                    start: max(0, first.start),
                    end: max(first.start + 0.12, last.end)))
            current.removeAll(keepingCapacity: true)
        }

        var currentSegment = placed[0].segment
        for item in placed {
            guard let first = current.first, let last = current.last else {
                current = [item.word]
                currentSegment = item.segment
                continue
            }

            let proposedText = (current.map(\.text) + [item.word.text]).joined(separator: " ")
            // Склейка посреди строки субтитров выглядит сломанной: граница
            // куска всегда завершает фразу.
            let crossesCut = item.segment != currentSegment
            let hasLargeGap = item.word.start - last.end > maxGap
            let tooManyWords = current.count >= maxWords
            let tooManyCharacters = proposedText.count > maxCharacters
            let tooLong = item.word.end - first.start > maxDuration

            if crossesCut || hasLargeGap || tooManyWords || tooManyCharacters || tooLong {
                flush()
            }
            current.append(item.word)
            currentSegment = item.segment
        }
        flush()
        return cues
    }
}

/// Геометрия подписи. Общая для запекания в MP4 и для слоя предпросмотра —
/// иначе превью расходится с готовым файлом.
enum ShortsSubtitleLayout {
    static let widthRatio: CGFloat = 0.88
    static let horizontalPaddingScale: CGFloat = 0.45
    static let verticalPaddingScale: CGFloat = 0.20
    static let lineHeightScale: CGFloat = 1.14
    static let cornerRadiusScale: CGFloat = 0.28
    static let shadowRadiusScale: CGFloat = 0.10
    static let shadowOffsetScale: CGFloat = 0.04
    /// Небольшой запас по горизонтали: ширина слова меряется системным
    /// шрифтовым API, а рисует текст CoreText — расхождение в пиксель-другой.
    static let highlightInsetScale: CGFloat = 0.04

    private static let bottomMarginScale: CGFloat = 1.25
    private static let horizontalBottomMarginRatio: CGFloat = 0.085
    /// В вертикальном кадре нижнюю пятую занимает интерфейс TikTok и Reels.
    private static let verticalBottomMarginRatio: CGFloat = 0.18

    static func bottomMargin(fontSize: CGFloat, canvasSize: CGSize) -> CGFloat {
        let ratio =
            canvasSize.height > canvasSize.width
            ? verticalBottomMarginRatio
            : horizontalBottomMarginRatio
        return max(fontSize * bottomMarginScale, canvasSize.height * ratio)
    }

    static func foregroundColor(for style: ShortsSubtitleStyle) -> NSColor {
        switch style {
        case .classic, .boxed: return .white
        case .accent: return .systemYellow
        }
    }

    /// Цвет звучащего слова. У жёлтого текста подсветка белая — контраст
    /// с остальной фразой сохраняется в обе стороны.
    static func highlightColor(for style: ShortsSubtitleStyle) -> NSColor {
        switch style {
        case .classic, .boxed: return .systemYellow
        case .accent: return .white
        }
    }
}

/// Накладывает фразы на видеокомпозицию для offline-экспорта.
enum ShortsSubtitleRenderer {
    static func applying(
        _ composition: AVMutableVideoComposition,
        cues: [ShortsSubtitleCue],
        style: ShortsSubtitleStyle,
        size: ShortsSubtitleSize,
        highlight: Bool,
        duration: Double
    ) -> AVMutableVideoComposition {
        guard !cues.isEmpty,
            duration > 0,
            composition.renderSize.width > 0,
            composition.renderSize.height > 0
        else { return composition }

        let renderSize = composition.renderSize
        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: renderSize)

        let videoLayer = CALayer()
        videoLayer.frame = parentLayer.bounds
        let subtitleLayer = CALayer()
        subtitleLayer.frame = parentLayer.bounds

        parentLayer.addSublayer(videoLayer)
        parentLayer.addSublayer(subtitleLayer)

        for cue in cues {
            subtitleLayer.addSublayer(
                captionLayer(
                    for: cue,
                    renderSize: renderSize,
                    style: style,
                    size: size,
                    highlight: highlight,
                    duration: duration))
        }

        composition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer)
        return composition
    }

    private static func captionLayer(
        for cue: ShortsSubtitleCue,
        renderSize: CGSize,
        style: ShortsSubtitleStyle,
        size: ShortsSubtitleSize,
        highlight: Bool,
        duration: Double
    ) -> CALayer {
        let fontSize = max(18, min(renderSize.width, renderSize.height) * size.scale)
        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        let horizontalPadding = fontSize * ShortsSubtitleLayout.horizontalPaddingScale
        let verticalPadding = fontSize * ShortsSubtitleLayout.verticalPaddingScale
        let width = renderSize.width * ShortsSubtitleLayout.widthRatio
        let maxTextWidth = max(1, width - horizontalPadding * 2)
        let textLayout = ShortsSubtitleTextWrapper.wrap(
            cue.text, font: font, maxWidth: maxTextWidth)
        let lineHeight = fontSize * ShortsSubtitleLayout.lineHeightScale
        let height = lineHeight * CGFloat(textLayout.lineCount) + verticalPadding * 2
        let bottomMargin = ShortsSubtitleLayout.bottomMargin(
            fontSize: fontSize, canvasSize: renderSize)

        let container = CALayer()
        container.frame = CGRect(
            x: (renderSize.width - width) / 2,
            y: bottomMargin,
            width: width,
            height: height)
        container.masksToBounds = false
        container.opacity = 0
        container.contentsScale = 2

        let textFrame = container.bounds.insetBy(dx: horizontalPadding, dy: verticalPadding)
        let textLayer = CALayer()
        textLayer.frame = textFrame
        textLayer.contentsScale = 2
        textLayer.contents = makeTextImage(
            textLayout.text,
            font: font,
            color: ShortsSubtitleLayout.foregroundColor(for: style),
            size: textLayer.bounds.size)

        if style == .boxed {
            container.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
            container.cornerRadius = fontSize * ShortsSubtitleLayout.cornerRadiusScale
        } else {
            textLayer.shadowColor = NSColor.black.cgColor
            textLayer.shadowOpacity = 0.95
            textLayer.shadowRadius = fontSize * ShortsSubtitleLayout.shadowRadiusScale
            textLayer.shadowOffset = CGSize(
                width: 0, height: -fontSize * ShortsSubtitleLayout.shadowOffsetScale)
        }

        container.addSublayer(textLayer)

        // Звучащее слово перекрашивается: поверх кладётся кусок той же фразы,
        // отрисованной вторым цветом, обрезанный по слову через contentsRect.
        // На фразу приходится ровно одна дополнительная картинка — минутный
        // ролик с картинкой на каждое слово стоил бы сотни мегабайт.
        if highlight,
            let highlighted = makeTextImage(
                textLayout.text,
                font: font,
                color: ShortsSubtitleLayout.highlightColor(for: style),
                size: textLayer.bounds.size)
        {
            let overlay = CALayer()
            overlay.frame = textFrame
            for layer in highlightedWordLayers(
                cue: cue, textLayout: textLayout, image: highlighted,
                bounds: CGRect(origin: .zero, size: textFrame.size),
                lineHeight: lineHeight, fontSize: fontSize, duration: duration)
            {
                overlay.addSublayer(layer)
            }
            container.addSublayer(overlay)
        }
        addVisibilityAnimation(
            to: container, start: cue.start, end: cue.end, duration: duration)
        return container
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
        fontSize: CGFloat,
        duration: Double
    ) -> [CALayer] {
        guard bounds.width > 0, bounds.height > 0 else { return [] }
        let inset = fontSize * ShortsSubtitleLayout.highlightInsetScale

        return cue.words.indices.compactMap { index -> CALayer? in
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
            addVisibilityAnimation(
                to: layer, start: cue.words[index].start, end: cue.words[index].end,
                duration: duration)
            return layer
        }
    }

    private static func makeTextImage(
        _ text: String,
        font: NSFont,
        color: NSColor,
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
        let attributedText = NSAttributedString(
            string: text,
            attributes: [
                .font: scaledFont,
                .foregroundColor: color.cgColor,
                .paragraphStyle: paragraphStyle,
            ])
        let framesetter = CTFramesetterCreateWithAttributedString(attributedText)
        let path = CGPath(
            rect: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)),
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

    private static func addVisibilityAnimation(
        to layer: CALayer,
        start visibleFrom: Double,
        end visibleTo: Double,
        duration: Double
    ) {
        let start = min(0.9999, max(0, visibleFrom / duration))
        let end = min(1, max(start + 0.0001, visibleTo / duration))
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [0, 1, 1, 0]
        animation.keyTimes = [
            NSNumber(value: 0), NSNumber(value: start),
            NSNumber(value: end), NSNumber(value: 1),
        ]
        animation.duration = duration
        animation.beginTime = AVCoreAnimationBeginTimeAtZero
        animation.isRemovedOnCompletion = false
        animation.fillMode = .both
        layer.add(animation, forKey: "shorts-subtitle-visibility")
    }
}

/// Где стоит слово после переноса: номер строки (сверху), отступ от левого
/// края своей строки и ширина. Слоя и холста эта логика не знает — рамку
/// подсветки из этого собирает рендерер.
struct ShortsSubtitleWordPlacement: Equatable, Sendable {
    let line: Int
    let x: CGFloat
    let width: CGFloat
}

struct ShortsSubtitleTextLayout: Equatable, Sendable {
    let text: String
    let lineCount: Int
    let lineWidths: [CGFloat]
    let placements: [ShortsSubtitleWordPlacement]
}

enum ShortsSubtitleTextWrapper {
    static func wrap(
        _ text: String,
        font: NSFont,
        maxWidth: CGFloat
    ) -> ShortsSubtitleTextLayout {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty, maxWidth > 0 else {
            return ShortsSubtitleTextLayout(
                text: text, lineCount: text.isEmpty ? 0 : 1,
                lineWidths: [width(of: text, font: font)], placements: [])
        }

        var lines: [String] = []
        var current = ""
        var placements: [ShortsSubtitleWordPlacement] = []

        func place(_ word: String, after prefix: String) {
            placements.append(
                ShortsSubtitleWordPlacement(
                    line: lines.count,
                    x: prefix.isEmpty ? 0 : width(of: prefix + " ", font: font),
                    width: width(of: word, font: font)))
        }

        for word in words {
            let chunks = splitWord(word, font: font, maxWidth: maxWidth)
            if chunks.count > 1 {
                if !current.isEmpty {
                    lines.append(current)
                    current = ""
                }
                lines.append(contentsOf: chunks.dropLast())
                current = chunks[chunks.count - 1]
                // Слово разорвано по символам — подсвечиваем его последний кусок.
                place(current, after: "")
                continue
            }

            if current.isEmpty {
                current = word
                place(word, after: "")
                continue
            }
            let candidate = "\(current) \(word)"
            if width(of: candidate, font: font) <= maxWidth {
                place(word, after: current)
                current = candidate
            } else {
                lines.append(current)
                current = word
                place(word, after: "")
            }
        }
        if !current.isEmpty { lines.append(current) }

        return ShortsSubtitleTextLayout(
            text: lines.joined(separator: "\n"),
            lineCount: lines.count,
            lineWidths: lines.map { width(of: $0, font: font) },
            placements: placements)
    }

    private static func splitWord(
        _ word: String,
        font: NSFont,
        maxWidth: CGFloat
    ) -> [String] {
        guard width(of: word, font: font) > maxWidth else { return [word] }
        var result: [String] = []
        var current = ""
        for character in word {
            let candidate = current + String(character)
            if !current.isEmpty, width(of: candidate, font: font) > maxWidth {
                result.append(current)
                current = String(character)
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func width(of text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }
}
