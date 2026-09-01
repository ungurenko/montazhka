import SwiftUI

/// Светлая визуальная система приложения.
enum Theme {
    static let background = Color(red: 0.96, green: 0.96, blue: 0.97)  // #F5F5F7
    static let workspace = Color(red: 0.94, green: 0.94, blue: 0.95)
    static let card = Color.white
    static let surfaceMuted = Color.black.opacity(0.025)
    static let border = Color.black.opacity(0.08)
    static let accent = Color(red: 0.0, green: 0.478, blue: 1.0)  // системный синий
    static let danger = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let warning = Color.orange
    static let success = Color.green
    static let selected = accent.opacity(0.08)
    static let hover = accent.opacity(0.05)
    static let pauseHighlight = Color(red: 1.0, green: 0.62, blue: 0.04)  // оранжевая подсветка пауз
    static let textPrimary = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let textSecondary = Color(red: 0.43, green: 0.43, blue: 0.45)
    static let waveform = Color(red: 0.35, green: 0.6, blue: 1.0)
    static let clipBackground = Color(red: 0.91, green: 0.94, blue: 1.0)

    static let radius: CGFloat = 12
    static let radiusSmall: CGFloat = 8

    enum Spacing {
        static let hairline: CGFloat = 2
        static let compact: CGFloat = 4
        static let small: CGFloat = 8
        static let snug: CGFloat = 12
        static let medium: CGFloat = 16
        static let large: CGFloat = 24
        static let xlarge: CGFloat = 32
    }

    enum TypeScale {
        static let screenTitle: CGFloat = 20
        static let sectionTitle: CGFloat = 15
        static let body: CGFloat = 13
        static let helper: CGFloat = 12
        static let time: CGFloat = 13
    }

    /// Тень означает высоту слоя, а не украшение: чем выше слой над
    /// содержимым, тем мягче и дальше падает тень.
    enum Elevation {
        /// Лежит на фоне: рабочие карточки, панели.
        case flat
        /// Приподнято над содержимым: плавающая верхняя панель.
        case raised
        /// Оторвано от плоскости: модальные окна, всплывающие подсказки.
        case floating

        var radius: CGFloat {
            switch self {
            case .flat: return 0
            case .raised: return 8
            case .floating: return 24
            }
        }

        var opacity: Double {
            switch self {
            case .flat: return 0
            case .raised: return 0.06
            case .floating: return 0.14
            }
        }

        var offsetY: CGFloat {
            switch self {
            case .flat: return 0
            case .raised: return 2
            case .floating: return 8
            }
        }
    }

    /// Движение интерфейса. Пружины вместо кривых: их можно перехватить
    /// на полпути, и они не «доигрывают» вопреки новому действию.
    enum Motion {
        /// Отклик на нажатие — самый короткий, чувствуется как касание.
        static let press = Animation.spring(response: 0.3, dampingFraction: 1.0)
        /// Наведение мыши — простое затухание, без физики.
        static let hover = Animation.easeOut(duration: 0.12)
        /// Появление и уход боковых панелей.
        static let panel = Animation.spring(response: 0.35, dampingFraction: 1.0)
        /// Смена экрана целиком.
        static let screen = Animation.spring(response: 0.4, dampingFraction: 1.0)

        /// При включённом «Уменьшении движения» любое перемещение
        /// заменяется коротким затуханием.
        static func adapting(_ animation: Animation, reduceMotion: Bool) -> Animation {
            reduceMotion ? .easeInOut(duration: 0.12) : animation
        }
    }
}

extension View {
    /// Основная рабочая поверхность: граница даёт иерархию без «карточного» шума.
    func cardStyle(radius: CGFloat = Theme.radius) -> some View {
        self
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Theme.border, lineWidth: 1)
            }
    }

    /// Небольшие строки и элементы выбора внутри рабочих поверхностей.
    func rowSurfaceStyle(selected: Bool = false) -> some View {
        self
            .background(selected ? Theme.selected : Theme.surfaceMuted)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                    .stroke(selected ? Theme.accent.opacity(0.45) : Theme.border, lineWidth: 1)
            }
    }

    /// Поднимает слой над содержимым: тень как высота, не как декор.
    func elevation(_ level: Theme.Elevation) -> some View {
        shadow(
            color: .black.opacity(level.opacity),
            radius: level.radius,
            x: 0,
            y: level.offsetY)
    }
}

enum TimeFormat {
    /// 63.25 → «1:03,2»
    static func short(_ seconds: Double) -> String {
        let s = max(0, seconds)
        let m = Int(s) / 60
        let sec = Int(s) % 60
        let tenth = Int((s - floor(s)) * 10)
        return String(format: "%d:%02d,%d", m, sec, tenth)
    }

    /// 63.25 → «1:03»
    static func compact(_ seconds: Double) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }

    /// Длительность прописью: «12 мин 30 сек» / «45 сек»
    static func spoken(_ seconds: Double) -> String {
        let s = Int(max(0, seconds).rounded())
        if s < 60 { return "\(s) сек" }
        let m = s / 60
        let rest = s % 60
        return rest == 0 ? "\(m) мин" : "\(m) мин \(rest) сек"
    }

    static func date(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMMM, HH:mm"
        return f
    }()
}
