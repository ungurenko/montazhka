import SwiftUI

// MARK: - Кнопки с текстом

/// Действие-ссылка: только текст акцентом, без подложки.
struct QuietButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        QuietButtonSurface(configuration: configuration, compact: compact)
    }
}

/// Подложка кнопки-ссылки: даёт ей наведение и нажатие, которых у
/// голого `.plain` нет вовсе.
private struct QuietButtonSurface: View {
    let configuration: ButtonStyleConfiguration
    let compact: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        configuration.label
            .typeStyle(compact ? .helperEmphasis : .bodyEmphasis)
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, compact ? Theme.Spacing.compact : Theme.Spacing.small)
            .padding(.vertical, Theme.Spacing.compact)
            .background(background)
            .clipShape(shape)
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

    private var pressScale: CGFloat {
        guard configuration.isPressed, isEnabled, !reduceMotion else { return 1 }
        return 0.97
    }

    private var pressAnimation: Animation {
        Theme.Motion.adapting(Theme.Motion.press, reduceMotion: reduceMotion)
    }

    @ViewBuilder
    private var background: some View {
        if configuration.isPressed {
            Theme.selected
        } else if hovering && isEnabled {
            Theme.hover
        } else {
            Color.clear
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
