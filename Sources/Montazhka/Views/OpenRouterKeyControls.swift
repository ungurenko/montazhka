import SwiftUI

/// Контракт «владельца ключа OpenRouter»: общий между EditorController
/// и ShortsController, поэтому блок управления ключом один на оба экрана.
@MainActor
protocol OpenRouterKeyControlling: AnyObject {
    var openRouterKeyStatus: OpenRouterKeyStatus { get }
    func validateSavedOpenRouterKey() async
    func deleteOpenRouterKey() async
    func saveAndValidateOpenRouterKey(_ key: String) async
}

/// Общий блок управления ключом OpenRouter для панелей «Умный монтаж» и нарезки
/// на shorts. Рендерится как два сиблинга (контролы + privacy-подсказка), чтобы
/// сохранить межблочные отступы родительского VStack каждой панели.
struct OpenRouterKeyControls: View {
    let controller: any OpenRouterKeyControlling
    @Binding var keyInput: String
    @Binding var replacingKey: Bool

    private var isCheckingKey: Bool {
        if case .checking = controller.openRouterKeyStatus { return true }
        return false
    }

    var body: some View {
        keyControls
        privacyNote
    }

    @ViewBuilder
    private var keyControls: some View {
        switch controller.openRouterKeyStatus {
        case .saved where !replacingKey:
            HStack(spacing: 10) {
                Label("Ключ сохранён", systemImage: "checkmark.circle.fill")
                    .typeStyle(.microEmphasis)
                    .foregroundStyle(.green)
                Spacer()
                Menu {
                    Button("Проверить ключ") { Task { await controller.validateSavedOpenRouterKey() } }
                    Button("Заменить ключ") { replacingKey = true }
                    Divider()
                    Button("Удалить ключ", role: .destructive) {
                        Task { await controller.deleteOpenRouterKey() }
                    }
                } label: {
                    Label("Настроить", systemImage: "ellipsis.circle")
                        .typeStyle(.microEmphasis)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(Theme.background)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
        default:
            VStack(alignment: .leading, spacing: 7) {
                SecureField("sk-or-v1-…", text: $keyInput)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Сохранить и проверить") {
                        Task {
                            await controller.saveAndValidateOpenRouterKey(keyInput)
                            if controller.openRouterKeyStatus == .saved {
                                keyInput = ""
                                replacingKey = false
                            }
                        }
                    }
                    .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCheckingKey)
                    if replacingKey {
                        Button("Отмена") {
                            keyInput = ""; replacingKey = false
                        }
                    }
                }
                switch controller.openRouterKeyStatus {
                case .checking:
                    Label("Проверяю ключ…", systemImage: "arrow.triangle.2.circlepath")
                        .typeStyle(.micro).foregroundStyle(Theme.textSecondary)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .typeStyle(.micro).foregroundStyle(Theme.danger)
                default:
                    EmptyView()
                }
            }
        }
    }

    private var privacyNote: some View {
        Label(
            "Ключ хранится обычным локальным файлом с доступом только твоему пользователю macOS. В OpenRouter уходит текст расшифровки; звук, видео и пути файлов остаются на Mac.",
            systemImage: "lock.shield.fill"
        )
        .typeStyle(.micro)
        .foregroundStyle(Theme.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.background)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
    }
}
