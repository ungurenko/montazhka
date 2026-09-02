import SwiftUI

/// Кнопка возврата в левом углу верхней панели.
struct TopBarBackButton {
    let title: String
    let accessibilityIdentifier: String
    var isDisabled = false
    let action: () -> Void
}

/// Верхняя панель экрана: возврат, заголовок, действия справа.
///
/// Раньше монтажный стол и нарезка на shorts собирали её каждый по-своему,
/// вплоть до отдельного хардкода отступа под кнопки окна. Теперь оба экрана
/// получают одинаковую высоту, отступы и поведение из одного места.
struct TopBar<Title: View, Actions: View>: View {
    var back: TopBarBackButton?
    @ViewBuilder let title: () -> Title
    @ViewBuilder let actions: () -> Actions

    @Environment(ActivityCenter.self) private var activity

    var body: some View {
        HStack(spacing: Theme.Spacing.snug) {
            if let back {
                Button(action: back.action) {
                    Label(back.title, systemImage: "chevron.left")
                }
                .buttonStyle(.mzQuiet)
                .disabled(back.isDisabled)
                .accessibilityIdentifier(back.accessibilityIdentifier)
            }

            title()

            Spacer(minLength: Theme.Spacing.snug)

            // Идущая работа видна отсюда всегда — даже когда панель,
            // которая её начала, закрыта.
            if let current = activity.primary {
                ActivityChip(activity: current) { activity.cancel(current.kind) }
                    .transition(.opacity)
            }

            actions()
        }
        .padding(.leading, Theme.Metrics.trafficLightInset - Theme.Spacing.small)
        .padding(.trailing, Theme.Spacing.medium)
        .frame(height: Theme.Metrics.topBarHeight)
        .background(alignment: .bottom) {
            Rectangle()
                .fill(Theme.border.opacity(0.6))
                .frame(height: 1)
        }
    }
}

extension TopBar where Actions == EmptyView {
    init(back: TopBarBackButton?, @ViewBuilder title: @escaping () -> Title) {
        self.init(back: back, title: title, actions: { EmptyView() })
    }
}

/// Обычный заголовок экрана: название и строка с подробностями под ним.
struct TopBarTitle: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
            Text(title)
                .typeStyle(.sectionTitle)
                .foregroundStyle(Theme.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .typeStyle(.helper)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
        }
    }
}
