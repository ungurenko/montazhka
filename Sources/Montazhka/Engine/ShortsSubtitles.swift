@preconcurrency import AVFoundation
import AppKit
import CoreText
import Foundation
import QuartzCore

/// Шрифт субтитров. Четыре подобранных гарнитуры: все есть в macOS, все знают
/// кириллицу и читаются на экране телефона. Если гарнитуры в системе не
/// оказалось, молча берём системную — лучше другой шрифт, чем пустые квадраты.
enum ShortsSubtitleFont: String, CaseIterable, Identifiable, Sendable {
    case system
    case grotesque
    case rounded
    case serif

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Системный"
        case .grotesque: return "Гротеск"
        case .rounded: return "Округлый"
        case .serif: return "С засечками"
        }
    }

    /// Имя гарнитуры в системе. nil — системный шрифт, он есть всегда.
    private var fontName: String? {
        switch self {
        case .system: return nil
        case .grotesque: return "HelveticaNeue-Bold"
        case .rounded: return "AvenirNext-Heavy"
        case .serif: return "Georgia-Bold"
        }
    }

    func font(ofSize size: CGFloat) -> NSFont {
        guard let fontName, let font = NSFont(name: fontName, size: size) else {
            return NSFont.systemFont(ofSize: size, weight: .bold)
        }
        return font
    }
}

/// Палитра цветов субтитров. Набор, а не свободная пипетка: каждый цвет
/// проверен на читаемость поверх видео.
enum ShortsSubtitleColor: String, CaseIterable, Identifiable, Sendable {
    case white
    case black
    case yellow
    case lime
    case coral
    case sky

    var id: String { rawValue }

    var title: String {
        switch self {
        case .white: return "Белый"
        case .black: return "Чёрный"
        case .yellow: return "Жёлтый"
        case .lime: return "Лаймовый"
        case .coral: return "Коралловый"
        case .sky: return "Голубой"
        }
    }

    var nsColor: NSColor {
        switch self {
        case .white: return NSColor(calibratedWhite: 1, alpha: 1)
        case .black: return NSColor(calibratedWhite: 0.1, alpha: 1)
        case .yellow: return NSColor(calibratedRed: 1, green: 0.83, blue: 0.15, alpha: 1)
        case .lime: return NSColor(calibratedRed: 0.66, green: 0.95, blue: 0.3, alpha: 1)
        case .coral: return NSColor(calibratedRed: 1, green: 0.42, blue: 0.38, alpha: 1)
        case .sky: return NSColor(calibratedRed: 0.35, green: 0.76, blue: 1, alpha: 1)
        }
    }
}

/// Что держит текст читаемым поверх любого кадра.
enum ShortsSubtitleBackground: String, CaseIterable, Identifiable, Sendable {
    case shadow
    case plate
    case outline
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shadow: return "Тень"
        case .plate: return "Плашка"
        case .outline: return "Обводка"
        case .none: return "Без подложки"
        }
    }
}

/// На какой высоте кадра стоит строка субтитров.
enum ShortsSubtitlePosition: String, CaseIterable, Identifiable, Sendable {
    case low
    case middle
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: return "Ниже"
        case .middle: return "Середина"
        case .high: return "Выше"
        }
    }

    /// Доля высоты кадра от нижнего края до нижней границы текста. В вертикальном
    /// кадре нижнюю пятую занимает интерфейс TikTok и Reels, поэтому там всё
    /// поднято выше.
    func bottomRatio(isVertical: Bool) -> CGFloat {
        switch self {
        case .low: return isVertical ? 0.14 : 0.06
        case .middle: return isVertical ? 0.24 : 0.14
        case .high: return isVertical ? 0.40 : 0.28
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

/// Готовый образ субтитров: выбирается одним нажатием и заполняет все поля
/// оформления разом.
enum ShortsSubtitlePreset: String, CaseIterable, Identifiable, Sendable {
    case classic
    case accent
    case plate
    case outline

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: return "Классика"
        case .accent: return "Акцент"
        case .plate: return "Плашка"
        case .outline: return "Обводка"
        }
    }

    var appearance: ShortsSubtitleAppearance {
        switch self {
        case .classic:
            return ShortsSubtitleAppearance(
                font: .system, size: .medium, textColor: .white,
                highlightColor: .yellow, background: .shadow, position: .low)
        case .accent:
            return ShortsSubtitleAppearance(
                font: .rounded, size: .large, textColor: .yellow,
                highlightColor: .white, background: .shadow, position: .low)
        case .plate:
            return ShortsSubtitleAppearance(
                font: .grotesque, size: .medium, textColor: .white,
                highlightColor: .yellow, background: .plate, position: .low)
        case .outline:
            return ShortsSubtitleAppearance(
                font: .system, size: .large, textColor: .white,
                highlightColor: .lime, background: .outline, position: .low)
        }
    }
}

/// Всё, что нужно знать обоим рендерам о внешнем виде субтитров: и слою
/// предпросмотра, и запеканию в MP4. Один источник правды — превью не может
/// разойтись с готовым файлом.
struct ShortsSubtitleAppearance: Equatable, Sendable {
    var font: ShortsSubtitleFont
    var size: ShortsSubtitleSize
    var textColor: ShortsSubtitleColor
    var highlightColor: ShortsSubtitleColor
    var background: ShortsSubtitleBackground
    var position: ShortsSubtitlePosition

    static let `default` = ShortsSubtitlePreset.classic.appearance

    /// Совпадает ли оформление с готовым образом. Отдельный флаг не нужен:
    /// ручная правка любого поля сама выводит выбор в «Свой».
    var preset: ShortsSubtitlePreset? {
        ShortsSubtitlePreset.allCases.first { $0.appearance == self }
    }

    func baseFontSize(canvasSize: CGSize) -> CGFloat {
        max(14, min(canvasSize.width, canvasSize.height) * size.scale)
    }
}

/// Настройки, которые выбираются в интерфейсе shorts и сохраняются между запусками.
struct ShortsSubtitleSettings: Equatable, Sendable {
    var enabled: Bool
    var appearance: ShortsSubtitleAppearance
    /// Подсветка звучащего слова — стандарт коротких роликов.
    var highlightActiveWord: Bool

    static let `default` = ShortsSubtitleSettings(
        enabled: false, appearance: .default, highlightActiveWord: true)

    static func saved(
        in store: any PreferenceStoring = UserDefaultsPreferenceStore.standard
    ) -> ShortsSubtitleSettings {
        let enabled = store.bool(forKey: Keys.enabled)
        // Строкой, а не флагом: отсутствие ключа надо отличать от «выключено»,
        // потому что подсветка включена по умолчанию.
        let highlight = store.string(forKey: Keys.highlight).map { $0 == "on" } ?? true
        // Каждое поле образа необязательно: чего в хранилище нет, то остаётся
        // из перенесённого старого стиля.
        var appearance = migratedAppearance(in: store)
        appearance.font = store.value(forKey: Keys.font) ?? appearance.font
        appearance.size = store.value(forKey: Keys.size) ?? appearance.size
        appearance.textColor = store.value(forKey: Keys.textColor) ?? appearance.textColor
        appearance.highlightColor =
            store.value(forKey: Keys.highlightColor) ?? appearance.highlightColor
        appearance.background = store.value(forKey: Keys.background) ?? appearance.background
        appearance.position = store.value(forKey: Keys.position) ?? appearance.position
        return ShortsSubtitleSettings(
            enabled: enabled, appearance: appearance, highlightActiveWord: highlight)
    }

    /// Три прежних стиля («Классика», «Акцент», «Подложка») переводим в образы,
    /// чтобы у тех, кто уже настроил субтитры, ничего не сбросилось.
    private static func migratedAppearance(in store: any PreferenceStoring) -> ShortsSubtitleAppearance {
        switch store.string(forKey: Keys.legacyStyle) {
        case "accent": return ShortsSubtitlePreset.accent.appearance
        case "boxed": return ShortsSubtitlePreset.plate.appearance
        default: return .default
        }
    }

    func save(in store: any PreferenceStoring = UserDefaultsPreferenceStore.standard) {
        store.set(enabled, forKey: Keys.enabled)
        store.set(highlightActiveWord ? "on" : "off", forKey: Keys.highlight)
        store.set(appearance.font.rawValue, forKey: Keys.font)
        store.set(appearance.size.rawValue, forKey: Keys.size)
        store.set(appearance.textColor.rawValue, forKey: Keys.textColor)
        store.set(appearance.highlightColor.rawValue, forKey: Keys.highlightColor)
        store.set(appearance.background.rawValue, forKey: Keys.background)
        store.set(appearance.position.rawValue, forKey: Keys.position)
    }

    func mode(with words: [TranscriptWord]) -> ShortsSubtitleMode {
        guard enabled, !words.isEmpty else { return .off }
        return .on(words: words, appearance: appearance, highlight: highlightActiveWord)
    }

    private enum Keys {
        static let enabled = "shorts.subtitlesEnabled"
        static let highlight = "shorts.subtitleHighlight"
        static let font = "shorts.subtitleFont"
        static let size = "shorts.subtitleSize"
        static let textColor = "shorts.subtitleTextColor"
        static let highlightColor = "shorts.subtitleHighlightColor"
        static let background = "shorts.subtitleBackground"
        static let position = "shorts.subtitlePosition"
        static let legacyStyle = "shorts.subtitleStyle"
    }
}

/// Данные для одного рендера. Слова входят в режим вместе с настройками,
/// поэтому exporter не может получить «включённые» субтитры отдельным флагом
/// и забыть передать их текст.
enum ShortsSubtitleMode: Equatable, Sendable {
    case off
    case on(
        words: [TranscriptWord], appearance: ShortsSubtitleAppearance,
        highlight: Bool)
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
    let appearance: ShortsSubtitleAppearance
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
        guard case let .on(words, appearance, highlight) = mode else { return nil }
        let cues = ShortsSubtitleCueBuilder.make(words: words, timeMap: timeMap)
        guard let cue = cues.first(where: { time >= $0.start && time < $0.end }) else {
            return nil
        }
        return ShortsSubtitleOverlay(
            words: cue.words.map(\.text), appearance: appearance,
            activeWordIndex: highlight ? cue.activeWordIndex(at: time) : nil)
    }
}

/// Делит слова локальной расшифровки на короткие читаемые фразы.
/// Это отдельная чистая логика: её можно проверять без запуска AVFoundation.
enum ShortsSubtitleCueBuilder {
    private static let maxWords = 4
    private static let maxCharacters = 30
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
    /// Безопасная зона: текст занимает не всю ширину кадра, поля остаются
    /// пустыми — так подпись не липнет к краям ни в каком формате.
    static let widthRatio: CGFloat = 0.86
    static let horizontalPaddingScale: CGFloat = 0.45
    static let verticalPaddingScale: CGFloat = 0.20
    static let lineHeightScale: CGFloat = 1.14
    static let cornerRadiusScale: CGFloat = 0.28
    static let shadowRadiusScale: CGFloat = 0.10
    static let shadowOffsetScale: CGFloat = 0.04
    static let outlineWidthScale: CGFloat = 0.075
    /// Небольшой запас по горизонтали: ширина слова меряется системным
    /// шрифтовым API, а рисует текст CoreText — расхождение в пиксель-другой.
    static let highlightInsetScale: CGFloat = 0.04
    /// Больше двух строк на экране телефона уже не читаются.
    static let maxLines = 2

    private static let minimumBottomRatio: CGFloat = 0.06

    static func bottomMargin(
        appearance: ShortsSubtitleAppearance,
        canvasSize: CGSize
    ) -> CGFloat {
        let isVertical = canvasSize.height > canvasSize.width
        let ratio = max(
            minimumBottomRatio, appearance.position.bottomRatio(isVertical: isVertical))
        return canvasSize.height * ratio
    }

    /// Шрифт, при котором фраза укладывается в две строки. Уменьшаем ступенями:
    /// мелкий текст лучше обрезанного.
    static func fittingFont(
        text: String,
        appearance: ShortsSubtitleAppearance,
        canvasSize: CGSize
    ) -> NSFont {
        let base = appearance.baseFontSize(canvasSize: canvasSize)
        var size = base
        for _ in 0...3 {
            let font = appearance.font.font(ofSize: size)
            let maxWidth = textWidth(fontSize: size, canvasSize: canvasSize)
            let layout = ShortsSubtitleTextWrapper.wrap(text, font: font, maxWidth: maxWidth)
            if layout.lineCount <= maxLines || size <= base * 0.7 { return font }
            size *= 0.9
        }
        return appearance.font.font(ofSize: size)
    }

    /// Ширина, доступная самому тексту: безопасная зона минус боковые отступы
    /// подложки.
    static func textWidth(fontSize: CGFloat, canvasSize: CGSize) -> CGFloat {
        max(1, canvasSize.width * widthRatio - fontSize * horizontalPaddingScale * 2)
    }
}

/// Накладывает фразы на видеокомпозицию для offline-экспорта.
enum ShortsSubtitleRenderer {
    static func applying(
        _ composition: AVMutableVideoComposition,
        cues: [ShortsSubtitleCue],
        appearance: ShortsSubtitleAppearance,
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
                    appearance: appearance,
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
        appearance: ShortsSubtitleAppearance,
        highlight: Bool,
        duration: Double
    ) -> CALayer {
        let font = ShortsSubtitleLayout.fittingFont(
            text: cue.text, appearance: appearance, canvasSize: renderSize)
        let fontSize = font.pointSize
        let horizontalPadding = fontSize * ShortsSubtitleLayout.horizontalPaddingScale
        let verticalPadding = fontSize * ShortsSubtitleLayout.verticalPaddingScale
        let width = renderSize.width * ShortsSubtitleLayout.widthRatio
        let maxTextWidth = ShortsSubtitleLayout.textWidth(
            fontSize: fontSize, canvasSize: renderSize)
        let textLayout = ShortsSubtitleTextWrapper.wrap(
            cue.text, font: font, maxWidth: maxTextWidth)
        let lineHeight = fontSize * ShortsSubtitleLayout.lineHeightScale
        let height = lineHeight * CGFloat(textLayout.lineCount) + verticalPadding * 2
        let bottomMargin = ShortsSubtitleLayout.bottomMargin(
            appearance: appearance, canvasSize: renderSize)

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
            color: appearance.textColor.nsColor,
            outlineWidth: appearance.background == .outline
                ? fontSize * ShortsSubtitleLayout.outlineWidthScale : 0,
            size: textLayer.bounds.size)

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
