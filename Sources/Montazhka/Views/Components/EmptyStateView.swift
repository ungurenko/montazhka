import SwiftUI

/// Экран или блок, когда показывать пока нечего.
///
/// Пустое состояние — это подсказка, а не пустота: оно называет, что здесь
/// появится, и по возможности даёт кнопку, которая к этому ведёт.
struct EmptyStateView: View {
    /// Кнопка, которая выводит пользователя из пустого состояния.
    struct Action {
        let title: String
        var accessibilityIdentifier: String?
        let perform: () -> Void
    }

    let systemImage: String
    let title: String
    var message: String?
    var action: Action?

    var body: some View {
        VStack(spacing: Theme.Spacing.snug) {
            Image(systemName: systemImage)
                .font(.system(size: IconScale.emptyState, weight: .light))
                .foregroundStyle(.white.opacity(0.5))

            VStack(spacing: Theme.Spacing.compact) {
                Text(title)
                    .typeStyle(.bodyEmphasis)
                    .foregroundStyle(.white.opacity(0.9))
                if let message {
                    Text(message)
                        .typeStyle(.helper)
                        .foregroundStyle(.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .multilineTextAlignment(.center)

            if let action {
                Button(action.title, action: action.perform)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier(action.accessibilityIdentifier ?? "")
            }
        }
        .frame(maxWidth: 320)
        .padding(Theme.Spacing.large)
    }
}
