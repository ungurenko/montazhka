import SwiftUI

/// Текстовые стили приложения.
///
/// Каждый стиль — это размер, вес и трекинг вместе, а не только размер:
/// крупный текст читается разреженным, поэтому у заголовков трекинг
/// отрицательный, а у мелких пояснений — слегка положительный.
enum TypeStyle {
    /// Заголовок экрана: «Сохранить видео», «Монтажка».
    case screenTitle
    /// Заголовок секции или панели.
    case sectionTitle
    /// Основной текст интерфейса.
    case body
    /// Основной текст с акцентом: названия строк списка, итоги.
    case bodyEmphasis
    /// Пояснение под контролом, второстепенная подпись.
    case helper
    /// Пояснение с акцентом: статус, короткий итог.
    case helperEmphasis
    /// Таймкод — моноширинный, чтобы цифры не прыгали.
    case time
    /// Таймкод текущей позиции — тот же моноширинный, но заметнее.
    case timeEmphasis

    var font: Font {
        switch self {
        case .screenTitle: return .system(size: 20, weight: .bold)
        case .sectionTitle: return .system(size: 15, weight: .semibold)
        case .body: return .system(size: 13, weight: .regular)
        case .bodyEmphasis: return .system(size: 13, weight: .semibold)
        case .helper: return .system(size: 12, weight: .regular)
        case .helperEmphasis: return .system(size: 12, weight: .semibold)
        case .time: return .system(size: 13, weight: .medium, design: .monospaced)
        case .timeEmphasis: return .system(size: 13, weight: .semibold, design: .monospaced)
        }
    }

    /// Межбуквенное расстояние: чем крупнее текст, тем плотнее набор.
    var tracking: CGFloat {
        switch self {
        case .screenTitle: return -0.3
        case .sectionTitle: return -0.1
        case .body, .bodyEmphasis: return 0
        case .helper, .helperEmphasis: return 0.05
        case .time, .timeEmphasis: return 0
        }
    }
}

/// Размеры значков SF Symbols — отдельная шкала, потому что значок
/// живёт по своим правилам и не должен тянуться за размером текста.
enum IconScale {
    /// Значок внутри строки текста.
    static let inline: CGFloat = 12
    /// Значок в кнопке панели инструментов.
    static let control: CGFloat = 15
    /// Крупный значок в карточке действия.
    static let card: CGFloat = 22
    /// Значок пустого состояния или ошибки.
    static let emptyState: CGFloat = 32
    /// Значок успеха в модальном окне.
    static let hero: CGFloat = 44
}

extension View {
    /// Применяет текстовый стиль целиком: шрифт вместе с трекингом.
    func typeStyle(_ style: TypeStyle) -> some View {
        self
            .font(style.font)
            .tracking(style.tracking)
    }
}
