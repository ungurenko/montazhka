@preconcurrency import AVFoundation
import AppKit
import CoreText
import Foundation
import QuartzCore

/// Шрифт субтитров. Четыре подобранных гарнитуры: все есть в macOS, все знают
/// кириллицу и читаются на экране телефона. Если гарнитуры в системе не
/// оказалось, молча берём системную — лучше другой шрифт, чем пустые квадраты.
enum ShortsSubtitleFont: String, Codable, CaseIterable, Identifiable, Sendable {
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
enum ShortsSubtitleColor: String, Codable, CaseIterable, Identifiable, Sendable {
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
enum ShortsSubtitleBackground: String, Codable, CaseIterable, Identifiable, Sendable {
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
enum ShortsSubtitlePosition: String, Codable, CaseIterable, Identifiable, Sendable {
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
enum ShortsSubtitleSize: String, Codable, CaseIterable, Identifiable, Sendable {
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
struct ShortsSubtitleAppearance: Codable, Equatable, Sendable {
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

    /// В горизонтальном кадре тот же кегль от короткой стороны вышел бы
    /// крупнее, чем нужно для длинной строки обычного ролика.
    func baseFontSize(canvasSize: CGSize) -> CGFloat {
        let orientationScale: CGFloat = canvasSize.width > canvasSize.height ? 0.8 : 1
        return max(14, min(canvasSize.width, canvasSize.height) * size.scale * orientationScale)
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

/// Как речь режется на фразы субтитров. У шортса фразы в 2–4 слова и быстрый
/// темп; у обычного горизонтального ролика — до двух строк, по предложениям.
struct SubtitleCueRules: Sendable, Equatable {
    var maxWords: Int
    var maxCharacters: Int
    var maxDuration: Double
    var maxGap: Double
    /// Конец предложения завершает фразу; запятая — только в уже длинной фразе.
    var breakAfterSentence: Bool
    /// Короткая фраза держится на экране хотя бы столько, но не заходит на следующую.
    var minDuration: Double

    static let shorts = SubtitleCueRules(
        maxWords: 4, maxCharacters: 30, maxDuration: 1.85, maxGap: 0.5,
        breakAfterSentence: false, minDuration: 0)
    static let horizontal = SubtitleCueRules(
        maxWords: 16, maxCharacters: 84, maxDuration: 6.0, maxGap: 0.8,
        breakAfterSentence: true, minDuration: 1.0)
}

/// Делит слова локальной расшифровки на короткие читаемые фразы.
/// Это отдельная чистая логика: её можно проверять без запуска AVFoundation.
enum ShortsSubtitleCueBuilder {
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

        return group(placed.map { ($0.word, $0.segment) }, rules: .shorts)
    }

    /// Фразы для черновика шортса.
    static func make(mapped words: [MappedTranscriptWord], notBefore: Double) -> [ShortsSubtitleCue] {
        make(mapped: words, notBefore: notBefore, rules: .shorts)
    }

    /// Фразы по словам, уже разложенным по ленте. Граница клипа завершает
    /// фразу, поэтому порядок клипов после перестановки не важен.
    /// `notBefore` — субтитры не показываются, пока на экране хук.
    static func make(
        mapped words: [MappedTranscriptWord],
        notBefore: Double = 0,
        rules: SubtitleCueRules
    ) -> [ShortsSubtitleCue] {
        let placed =
            words
            .filter { $0.timelineStart >= notBefore && $0.timelineEnd > $0.timelineStart }
            .sorted { $0.timelineStart < $1.timelineStart }
            .compactMap { word -> (ShortsSubtitleWord, AnyHashable)? in
                let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return (ShortsSubtitleWord(text: text, start: word.timelineStart, end: word.timelineEnd), word.clipID)
            }
        return group(placed, rules: rules)
    }

    /// Собирает слова в короткие фразы. `segment` — кусок ролика: фраза
    /// никогда не переходит через склейку.
    private static func group(
        _ placed: [(word: ShortsSubtitleWord, segment: AnyHashable)],
        rules: SubtitleCueRules
    ) -> [ShortsSubtitleCue] {
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

            let currentText = current.map(\.text).joined(separator: " ")
            let proposedText = currentText + " " + item.word.text
            // Склейка посреди строки субтитров выглядит сломанной: граница
            // куска всегда завершает фразу.
            let crossesCut = item.segment != currentSegment
            let hasLargeGap = item.word.start - last.end > rules.maxGap
            let tooManyWords = current.count >= rules.maxWords
            let tooManyCharacters = proposedText.count > rules.maxCharacters
            let tooLong = item.word.end - first.start > rules.maxDuration
            let thoughtEnded =
                rules.breakAfterSentence
                && endsThought(currentText, lastWord: last.text, maxCharacters: rules.maxCharacters)

            if crossesCut || hasLargeGap || tooManyWords || tooManyCharacters || tooLong || thoughtEnded {
                flush()
            }
            current.append(item.word)
            currentSegment = item.segment
        }
        flush()
        return rules.minDuration > 0 ? extended(cues, toAtLeast: rules.minDuration) : cues
    }

    /// Конец предложения всегда завершает фразу. Запятая — только когда фраза
    /// заняла больше 60% длины: иначе строка рвалась бы на каждом обороте.
    /// Закрывающие кавычки и скобки после знака не мешают: «так.» — тоже конец.
    private static func endsThought(_ text: String, lastWord: String, maxCharacters: Int) -> Bool {
        var word = Substring(lastWord)
        while let character = word.last, "»\"”’)".contains(character) { word = word.dropLast() }
        guard let mark = word.last else { return false }
        if ".!?…".contains(mark) { return true }
        return mark == "," && Double(text.count) > Double(maxCharacters) * 0.6
    }

    /// Короткая фраза дотягивается до `minDuration`, но не дальше начала
    /// следующей: две фразы на экране одновременно не читаются. Слова внутри
    /// не трогаются — подсветка идёт по их настоящему времени.
    private static func extended(_ cues: [ShortsSubtitleCue], toAtLeast minDuration: Double) -> [ShortsSubtitleCue] {
        cues.indices.map { index in
            let cue = cues[index]
            var end = cue.start + minDuration
            if index + 1 < cues.count { end = min(end, cues[index + 1].start) }
            return ShortsSubtitleCue(words: cue.words, start: cue.start, end: max(cue.end, end))
        }
    }
}

/// Геометрия подписи. Общая для запекания в MP4 и для слоя предпросмотра —
/// иначе превью расходится с готовым файлом.
enum ShortsSubtitleLayout {
    /// Безопасная зона: текст занимает не всю ширину кадра, поля остаются
    /// пустыми — так подпись не липнет к краям ни в каком формате. В
    /// горизонтальном кадре строка на всю ширину читалась бы слишком длинной.
    static func widthRatio(for canvas: CGSize) -> CGFloat {
        canvas.width > canvas.height ? 0.72 : 0.86
    }
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

    /// Высота строки: не меньше настоящей высоты шрифта. У системного шрифта и
    /// Avenir строка выше 1.14 кегля — строку, которая не влезла по высоте,
    /// CoreText молча не рисует, и субтитры пропадали целиком.
    static func lineHeight(for font: NSFont) -> CGFloat {
        max(font.pointSize * lineHeightScale, ceil(font.ascender - font.descender + font.leading))
    }

    /// Ширина, доступная самому тексту: безопасная зона минус боковые отступы
    /// подложки.
    static func textWidth(fontSize: CGFloat, canvasSize: CGSize) -> CGFloat {
        max(1, canvasSize.width * widthRatio(for: canvasSize) - fontSize * horizontalPaddingScale * 2)
    }
}

/// Неподвижный снимок надписей в заданный момент — для сетки кадров агента.
/// AVAssetImageGenerator не умеет Core Animation, поэтому надписи рисуются
/// отдельно тем же слоем, что и в экспорте, и кладутся поверх кадра.
enum ShortsOverlaySnapshot {
    /// Разовый снимок — тем же рисовальщиком, что кладёт надписи в MP4.
    static func image(
        at time: Double,
        renderSize: CGSize,
        cues: [ShortsSubtitleCue],
        appearance: ShortsSubtitleAppearance,
        highlight: Bool,
        hook: ShortsHook?
    ) -> CGImage? {
        OverlayFrameRenderer(
            renderSize: renderSize, cues: cues, appearance: appearance, highlight: highlight, hook: hook)?
            .image(at: time)
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
