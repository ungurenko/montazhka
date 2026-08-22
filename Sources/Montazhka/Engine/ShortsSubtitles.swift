import AVFoundation
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

    static let `default` = ShortsSubtitleSettings(
        enabled: false, style: .classic, size: .medium)

    static var saved: ShortsSubtitleSettings {
        let defaults = UserDefaults.standard
        let style =
            ShortsSubtitleStyle(
                rawValue: defaults.string(forKey: Keys.style) ?? "") ?? .classic
        let size =
            ShortsSubtitleSize(
                rawValue: defaults.string(forKey: Keys.size) ?? "") ?? .medium
        let enabled = defaults.object(forKey: Keys.enabled) as? Bool ?? false
        return ShortsSubtitleSettings(enabled: enabled, style: style, size: size)
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(enabled, forKey: Keys.enabled)
        defaults.set(style.rawValue, forKey: Keys.style)
        defaults.set(size.rawValue, forKey: Keys.size)
    }

    func mode(with words: [TranscriptWord]) -> ShortsSubtitleMode {
        guard enabled, !words.isEmpty else { return .off }
        return .on(words: words, style: style, size: size)
    }

    private enum Keys {
        static let enabled = "shorts.subtitlesEnabled"
        static let style = "shorts.subtitleStyle"
        static let size = "shorts.subtitleSize"
    }
}

/// Данные для одного рендера. Слова входят в режим вместе с настройками,
/// поэтому exporter не может получить «включённые» субтитры отдельным флагом
/// и забыть передать их текст.
enum ShortsSubtitleMode: Equatable, Sendable {
    case off
    case on(words: [TranscriptWord], style: ShortsSubtitleStyle, size: ShortsSubtitleSize)
}

/// Временная шкала субтитров для одного кандидата.
/// Все значения относятся к исходной композиции, а `relativeTo` задаёт начало
/// шкалы, на которой фраза появляется в экспортируемом ролике.
struct ShortsSubtitleTimeline: Equatable, Sendable {
    let sourceStart: Double
    let sourceEnd: Double
    let relativeTo: Double
    let duration: Double

    static let empty = ShortsSubtitleTimeline(
        sourceStart: 0,
        sourceEnd: 0,
        relativeTo: 0,
        duration: 0)
}

/// Одна фраза, которая показывается в заданном диапазоне времени.
/// Время уже приведено к шкале конкретного предпросмотра или экспорта.
struct ShortsSubtitleCue: Equatable, Sendable {
    let text: String
    let start: Double
    let end: Double
}

/// Данные для текстового слоя поверх AVPlayer. Preview рисует этот слой в UI,
/// потому что AVVideoCompositionCoreAnimationTool предназначен для offline-рендера.
struct ShortsSubtitleOverlay: Equatable, Sendable {
    let text: String
    let style: ShortsSubtitleStyle
    let size: ShortsSubtitleSize
}

enum ShortsSubtitleOverlayBuilder {
    static func make(
        at time: Double,
        sourceStart: Double,
        sourceEnd: Double,
        mode: ShortsSubtitleMode
    ) -> ShortsSubtitleOverlay? {
        guard case let .on(words, style, size) = mode else { return nil }
        let cues = ShortsSubtitleCueBuilder.make(
            words: words,
            sourceStart: sourceStart,
            sourceEnd: sourceEnd,
            relativeTo: 0)
        guard let cue = cues.first(where: { time >= $0.start && time < $0.end }) else {
            return nil
        }
        return ShortsSubtitleOverlay(text: cue.text, style: style, size: size)
    }
}

/// Делит слова локальной расшифровки на короткие читаемые фразы.
/// Это отдельная чистая логика: её можно проверять без запуска AVFoundation.
enum ShortsSubtitleCueBuilder {
    private static let maxWords = 4
    private static let maxCharacters = 34
    private static let maxDuration = 1.85
    private static let maxGap = 0.50

    static func make(
        words: [TranscriptWord],
        sourceStart: Double,
        sourceEnd: Double,
        relativeTo: Double
    ) -> [ShortsSubtitleCue] {
        guard sourceEnd > sourceStart else { return [] }

        struct TimedWord {
            let text: String
            let start: Double
            let end: Double
        }

        let visibleWords =
            words
            .filter { $0.end > sourceStart && $0.start < sourceEnd }
            .compactMap { word -> TimedWord? in
                let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                let start = max(sourceStart, word.start)
                let end = min(sourceEnd, word.end)
                guard end > start else { return nil }
                return TimedWord(text: text, start: start, end: end)
            }
            .sorted { left, right in
                if left.start != right.start { return left.start < right.start }
                return left.end < right.end
            }

        guard !visibleWords.isEmpty else { return [] }

        var cues: [ShortsSubtitleCue] = []
        var current: [TimedWord] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let start = max(0, first.start - relativeTo)
            let end = max(start + 0.12, last.end - relativeTo)
            cues.append(
                ShortsSubtitleCue(
                    text: current.map(\.text).joined(separator: " "),
                    start: start,
                    end: end))
            current.removeAll(keepingCapacity: true)
        }

        for word in visibleWords {
            guard let first = current.first, let last = current.last else {
                current = [word]
                continue
            }

            let proposedText = (current.map(\.text) + [word.text]).joined(separator: " ")
            let hasLargeGap = word.start - last.end > maxGap
            let tooManyWords = current.count >= maxWords
            let tooManyCharacters = proposedText.count > maxCharacters
            let tooLong = word.end - first.start > maxDuration

            if hasLargeGap || tooManyWords || tooManyCharacters || tooLong {
                flush()
            }
            current.append(word)
        }
        flush()
        return cues
    }
}

/// Накладывает фразы на видеокомпозицию для offline-экспорта.
enum ShortsSubtitleRenderer {
    static func applying(
        _ composition: AVMutableVideoComposition,
        cues: [ShortsSubtitleCue],
        style: ShortsSubtitleStyle,
        size: ShortsSubtitleSize,
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
        duration: Double
    ) -> CALayer {
        let fontSize = max(18, min(renderSize.width, renderSize.height) * size.scale)
        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        let horizontalPadding = fontSize * Layout.horizontalPaddingScale
        let verticalPadding = fontSize * Layout.verticalPaddingScale
        let width = renderSize.width * Layout.widthRatio
        let maxTextWidth = max(1, width - horizontalPadding * 2)
        let textLayout = ShortsSubtitleTextWrapper.wrap(
            cue.text, font: font, maxWidth: maxTextWidth)
        let lineHeight = fontSize * Layout.lineHeightScale
        let height = lineHeight * CGFloat(textLayout.lineCount) + verticalPadding * 2
        let bottomMargin = max(fontSize * Layout.bottomMarginScale, renderSize.height * Layout.bottomMarginRatio)

        let container = CALayer()
        container.frame = CGRect(
            x: (renderSize.width - width) / 2,
            y: bottomMargin,
            width: width,
            height: height)
        container.masksToBounds = false
        container.opacity = 0
        container.contentsScale = 2

        let textLayer = CALayer()
        textLayer.frame = container.bounds.insetBy(
            dx: horizontalPadding,
            dy: verticalPadding)
        textLayer.contentsScale = 2
        textLayer.contents = makeTextImage(
            textLayout.text,
            font: font,
            color: foregroundColor(for: style),
            size: textLayer.bounds.size)

        if style == .boxed {
            container.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
            container.cornerRadius = fontSize * 0.28
        } else {
            textLayer.shadowColor = NSColor.black.cgColor
            textLayer.shadowOpacity = 0.95
            textLayer.shadowRadius = fontSize * 0.10
            textLayer.shadowOffset = CGSize(width: 0, height: -fontSize * 0.04)
        }

        container.addSublayer(textLayer)
        addVisibilityAnimation(to: container, cue: cue, duration: duration)
        return container
    }

    private enum Layout {
        static let widthRatio: CGFloat = 0.88
        static let horizontalPaddingScale: CGFloat = 0.45
        static let verticalPaddingScale: CGFloat = 0.20
        static let lineHeightScale: CGFloat = 1.14
        static let bottomMarginScale: CGFloat = 1.25
        static let bottomMarginRatio: CGFloat = 0.085
    }

    private static func foregroundColor(for style: ShortsSubtitleStyle) -> NSColor {
        switch style {
        case .classic, .boxed: return .white
        case .accent: return .systemYellow
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
        cue: ShortsSubtitleCue,
        duration: Double
    ) {
        let start = min(0.9999, max(0, cue.start / duration))
        let end = min(1, max(start + 0.0001, cue.end / duration))
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

struct ShortsSubtitleTextLayout: Equatable, Sendable {
    let text: String
    let lineCount: Int
}

enum ShortsSubtitleTextWrapper {
    static func wrap(
        _ text: String,
        font: NSFont,
        maxWidth: CGFloat
    ) -> ShortsSubtitleTextLayout {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty, maxWidth > 0 else {
            return ShortsSubtitleTextLayout(text: text, lineCount: text.isEmpty ? 0 : 1)
        }

        var lines: [String] = []
        var current = ""
        for word in words {
            let chunks = splitWord(word, font: font, maxWidth: maxWidth)
            if chunks.count > 1 {
                if !current.isEmpty {
                    lines.append(current)
                    current = ""
                }
                lines.append(contentsOf: chunks.dropLast())
                current = chunks[chunks.count - 1]
                continue
            }

            if current.isEmpty {
                current = word
                continue
            }
            let candidate = "\(current) \(word)"
            if width(of: candidate, font: font) <= maxWidth {
                current = candidate
            } else {
                lines.append(current)
                current = word
            }
        }
        if !current.isEmpty { lines.append(current) }

        return ShortsSubtitleTextLayout(
            text: lines.joined(separator: "\n"), lineCount: lines.count)
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
