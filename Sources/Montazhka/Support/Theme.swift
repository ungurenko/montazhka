import SwiftUI

/// Светлая палитра в стиле Apple: много воздуха, мягкие скругления.
enum Theme {
    static let background = Color(red: 0.96, green: 0.96, blue: 0.97)      // #F5F5F7
    static let card = Color.white
    static let accent = Color(red: 0.0, green: 0.478, blue: 1.0)           // системный синий
    static let danger = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let pauseHighlight = Color(red: 1.0, green: 0.62, blue: 0.04)   // оранжевая подсветка пауз
    static let textPrimary = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let textSecondary = Color(red: 0.43, green: 0.43, blue: 0.45)
    static let waveform = Color(red: 0.35, green: 0.6, blue: 1.0)
    static let clipBackground = Color(red: 0.91, green: 0.94, blue: 1.0)

    static let radius: CGFloat = 12
    static let radiusSmall: CGFloat = 8
}

extension View {
    /// Белая карточка со скруглением и лёгкой тенью.
    func cardStyle(radius: CGFloat = Theme.radius) -> some View {
        self
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
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
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMMM, HH:mm"
        return f.string(from: date)
    }
}
