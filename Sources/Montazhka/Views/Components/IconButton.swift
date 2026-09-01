import SwiftUI

/// Типовые размеры кнопки-значка. Раньше каждый экран задавал их вручную,
/// поэтому одинаковые по смыслу кнопки отличались на пару точек.
enum IconButtonSize {
    /// Инструмент ленты и зум: небольшой прямоугольник.
    case toolbar
    /// Кнопка панели воспроизведения.
    case transport
    /// Плей/пауза — главная кнопка панели воспроизведения.
    case transportPrimary

    var iconSize: CGFloat {
        switch self {
        case .toolbar: return 13
        case .transport: return IconScale.control
        case .transportPrimary: return IconScale.card
        }
    }

    var width: CGFloat {
        switch self {
        case .toolbar: return 26
        case .transport: return 34
        case .transportPrimary: return 44
        }
    }

    var height: CGFloat {
        switch self {
        case .toolbar: return 22
        case .transport: return 34
        case .transportPrimary: return 44
        }
    }

    var isCircular: Bool {
        switch self {
        case .toolbar: return false
        case .transport, .transportPrimary: return true
        }
    }
}

/// Кнопка без подписи с подсказкой при наведении.
///
/// Единственная кнопка-значок в приложении: заменила `ControlButton` из
/// монтажного стола и `ZoomButton` с `ToolButton` из ленты клипов.
struct IconButton: View {
    let icon: String
    let help: String
    var size: IconButtonSize = .transport
    var prominence: IconButtonStyle.Prominence = .quiet
    /// Для кнопок-переключателей: «Включено» / «Выключено».
    var stateDescription: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
        }
        .buttonStyle(
            .mzIcon(
                prominence,
                iconSize: size.iconSize,
                width: size.width,
                height: size.height,
                isCircular: size.isCircular)
        )
        .help(help)
        .accessibilityLabel(help)
        .accessibilityValue(stateDescription ?? "")
    }
}
