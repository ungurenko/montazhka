import SwiftUI

/// Плашка о результате: что случилось и что с этим делать.
///
/// Собрала в одно место пять почти одинаковых блоков, которые раньше каждая
/// панель рисовала сама. Подсказка `hint` обязательна по смыслу: сообщение
/// об ошибке без следующего шага оставляет пользователя в тупике.
struct StatusBanner: View {
    enum Kind {
        case error
        case warning
        case success
        case info

        var systemImage: String {
            switch self {
            case .error: return "exclamationmark.triangle.fill"
            case .warning: return "exclamationmark.circle.fill"
            case .success: return "checkmark.circle.fill"
            case .info: return "info.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .error: return Theme.danger
            case .warning: return Theme.warning
            case .success: return Theme.success
            case .info: return Theme.accent
            }
        }
    }

    struct Action {
        let title: String
        var accessibilityIdentifier: String?
        let perform: () -> Void
    }

    let kind: Kind
    let title: String
    var hint: String?
    var actions: [Action] = []

    init(kind: Kind, title: String, hint: String? = nil, actions: [Action] = []) {
        self.kind = kind
        self.title = title
        self.hint = hint
        self.actions = actions
    }

    /// Ошибка уже разделена на «что случилось» и «что делать» — берём как есть.
    init(kind: Kind = .error, error: UserFacingError, actions: [Action] = []) {
        self.init(kind: kind, title: error.what, hint: error.hint, actions: actions)
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.small) {
            Image(systemName: kind.systemImage)
                .font(.system(size: IconScale.inline + 2))
                .foregroundStyle(kind.tint)

            VStack(alignment: .leading, spacing: Theme.Spacing.compact) {
                Text(title)
                    .typeStyle(.helperEmphasis)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if let hint {
                    Text(hint)
                        .typeStyle(.helper)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !actions.isEmpty {
                    HStack(spacing: Theme.Spacing.small) {
                        ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                            Button(action.title, action: action.perform)
                                .buttonStyle(.mzQuiet(compact: true))
                                .accessibilityIdentifier(action.accessibilityIdentifier ?? "")
                        }
                    }
                    .padding(.top, Theme.Spacing.hairline)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.snug)
        .background(kind.tint.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
    }
}
