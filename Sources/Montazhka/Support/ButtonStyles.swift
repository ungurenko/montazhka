import SwiftUI

// MARK: - Кнопки с текстом

/// Главное действие экрана: заливка акцентом, белый текст.
struct PrimaryButtonStyle: ButtonStyle {
    /// Растянуть по ширине родителя — для кнопок внизу панели.
    var fillsWidth = false
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        TextButtonSurface(
            configuration: configuration,
            kind: .primary,
            fillsWidth: fillsWidth,
            compact: compact)
    }
}

/// Второстепенное действие: белая подложка с границей.
struct SecondaryButtonStyle: ButtonStyle {
    var fillsWidth = false
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        TextButtonSurface(
            configuration: configuration,
            kind: .secondary,
            fillsWidth: fillsWidth,
            compact: compact)
    }
}

/// Действие-ссылка: только текст акцентом, без подложки.
struct QuietButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        TextButtonSurface(
            configuration: configuration,
            kind: .quiet,
            fillsWidth: false,
            compact: compact)
    }
}

private enum TextButtonKind {
    case primary
    case secondary
    case quiet
}

/// Общая подложка текстовых кнопок: держит все четыре состояния —
/// обычное, наведение, нажатие и выключенное.
private struct TextButtonSurface: View {
    let configuration: ButtonStyleConfiguration
    let kind: TextButtonKind
    let fillsWidth: Bool
    let compact: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        configuration.label
            .typeStyle(compact ? .helperEmphasis : .bodyEmphasis)
            .foregroundStyle(foreground)
            .padding(.horizontal, compact ? Theme.Spacing.small : Theme.Spacing.snug)
            .padding(.vertical, compact ? Theme.Spacing.compact : Theme.Spacing.small)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .background(background)
            .clipShape(shape)
            .overlay { borderOverlay }
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(pressScale)
            .animation(pressAnimation, value: configuration.isPressed)
            .animation(Theme.Motion.hover, value: hovering)
            .onHover { hovering = $0 }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
    }

    private var isHighlighted: Bool { hovering && isEnabled }

    private var pressScale: CGFloat {
        guard configuration.isPressed, isEnabled, !reduceMotion else { return 1 }
        return 0.97
    }

    private var pressAnimation: Animation {
        Theme.Motion.adapting(Theme.Motion.press, reduceMotion: reduceMotion)
    }

    private var foreground: Color {
        switch kind {
        case .primary: return .white
        case .secondary: return Theme.textPrimary
        case .quiet: return Theme.accent
        }
    }

    @ViewBuilder
    private var background: some View {
        switch kind {
        case .primary:
            Theme.accent.opacity(configuration.isPressed ? 0.82 : (isHighlighted ? 0.92 : 1))
        case .secondary:
            if configuration.isPressed {
                Theme.selected
            } else if isHighlighted {
                Theme.hover
            } else {
                Theme.card
            }
        case .quiet:
            if configuration.isPressed {
                Theme.selected
            } else if isHighlighted {
                Theme.hover
            } else {
                Color.clear
            }
        }
    }

    @ViewBuilder
    private var borderOverlay: some View {
        if kind == .secondary {
            shape.stroke(isHighlighted ? Theme.accent.opacity(0.35) : Theme.border, lineWidth: 1)
        }
    }
}

// MARK: - Кнопки-значки

/// Кнопка без подписи: панель воспроизведения, инструменты ленты, зум.
///
/// Заменяет три почти одинаковые самодельные кнопки, которые раньше жили
/// в `EditorView` и `TimelineView`, и добавляет им отклик на наведение и нажатие.
struct IconButtonStyle: ButtonStyle {
    enum Prominence {
        /// Обычная кнопка панели инструментов.
        case quiet
        /// Включённый инструмент: подсветка акцентом.
        case active
        /// Главное действие: заливка акцентом, белый значок.
        case filled
    }

    var prominence: Prominence = .quiet
    var iconSize: CGFloat = IconScale.control
    var width: CGFloat = 34
    var height: CGFloat = 34
    var isCircular = true

    func makeBody(configuration: Configuration) -> some View {
        IconButtonSurface(
            configuration: configuration,
            prominence: prominence,
            iconSize: iconSize,
            width: width,
            height: height,
            isCircular: isCircular)
    }
}

private struct IconButtonSurface: View {
    let configuration: ButtonStyleConfiguration
    let prominence: IconButtonStyle.Prominence
    let iconSize: CGFloat
    let width: CGFloat
    let height: CGFloat
    let isCircular: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.system(size: iconSize, weight: prominence == .quiet ? .medium : .semibold))
            .foregroundStyle(foreground)
            .frame(width: width, height: height)
            .background(background)
            .clipShape(shape)
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.35)
            .scaleEffect(pressScale)
            .animation(pressAnimation, value: configuration.isPressed)
            .animation(Theme.Motion.hover, value: hovering)
            .onHover { hovering = $0 }
    }

    private var shape: AnyShape {
        isCircular
            ? AnyShape(Circle())
            : AnyShape(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
    }

    private var isHighlighted: Bool { hovering && isEnabled }

    private var pressScale: CGFloat {
        guard configuration.isPressed, isEnabled, !reduceMotion else { return 1 }
        return 0.92
    }

    private var pressAnimation: Animation {
        Theme.Motion.adapting(Theme.Motion.press, reduceMotion: reduceMotion)
    }

    private var foreground: Color {
        switch prominence {
        case .quiet: return Theme.textPrimary
        case .active: return Theme.accent
        case .filled: return .white
        }
    }

    @ViewBuilder
    private var background: some View {
        switch prominence {
        case .quiet:
            if configuration.isPressed {
                Theme.selected
            } else if isHighlighted {
                Theme.hover
            } else {
                Color.clear
            }
        case .active:
            Theme.accent.opacity(configuration.isPressed ? 0.22 : (isHighlighted ? 0.18 : 0.12))
        case .filled:
            Theme.accent.opacity(configuration.isPressed ? 0.82 : (isHighlighted ? 0.92 : 1))
        }
    }
}

// MARK: - Короткая запись

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var mzPrimary: Self { .init() }
    static func mzPrimary(fillsWidth: Bool = false, compact: Bool = false) -> Self {
        .init(fillsWidth: fillsWidth, compact: compact)
    }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var mzSecondary: Self { .init() }
    static func mzSecondary(fillsWidth: Bool = false, compact: Bool = false) -> Self {
        .init(fillsWidth: fillsWidth, compact: compact)
    }
}

extension ButtonStyle where Self == QuietButtonStyle {
    static var mzQuiet: Self { .init() }
    static func mzQuiet(compact: Bool) -> Self { .init(compact: compact) }
}

extension ButtonStyle where Self == IconButtonStyle {
    static var mzIcon: Self { .init() }

    static func mzIcon(
        _ prominence: IconButtonStyle.Prominence = .quiet,
        iconSize: CGFloat = IconScale.control,
        width: CGFloat = 34,
        height: CGFloat = 34,
        isCircular: Bool = true
    ) -> Self {
        .init(
            prominence: prominence,
            iconSize: iconSize,
            width: width,
            height: height,
            isCircular: isCircular)
    }
}
