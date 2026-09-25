import Foundation

/// Как вертикальный кадр показывает исходник.
public enum ShortsDraftLayout: String, Codable, CaseIterable, Sendable {
    /// Решает программа по лицам в кадре.
    case auto
    /// Рамка 9:16 следит за лицом.
    case face
    /// Экран целиком сверху, лицо крупно снизу.
    case split
    /// Кадр целиком на тёмном фоне.
    case fit
}

/// Крупная надпись в первые секунды ролика.
public struct ShortsHook: Codable, Equatable, Sendable {
    static let defaultDuration = 2.5

    var text: String
    var duration: Double

    init(text: String, duration: Double = ShortsHook.defaultDuration) {
        self.text = text
        self.duration = duration
    }
}

/// Субтитры черновика. Их нет, пока пользователь не попросил.
public struct ShortsDraftSubtitles: Codable, Equatable, Sendable {
    var appearance: ShortsSubtitleAppearance
    var highlight: Bool
}

/// Плавный наезд. Держится за время исходника, а не ленты: правки ленты
/// его не сдвигают, а вырезанные куски просто уносят его часть с собой.
public struct ShortsZoom: Codable, Equatable, Sendable {
    var sourceID: UUID
    var sourceStart: Double
    var sourceEnd: Double
    var scale: Double
}

/// Оформление проекта-черновика шортса. У обычного проекта его нет.
public struct ShortsPresentation: Codable, Equatable, Sendable {
    var title: String
    var reason: String
    /// Что попросили.
    var layout: ShortsDraftLayout
    /// Что получилось после авто-выбора; `auto` здесь не бывает.
    var resolvedLayout: ShortsDraftLayout
    var hook: ShortsHook?
    var subtitles: ShortsDraftSubtitles?
    var zooms: [ShortsZoom]
    /// Куда выгружается MP4 черновика.
    var exportPath: String?
}
