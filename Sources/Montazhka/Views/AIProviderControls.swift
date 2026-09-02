import SwiftUI

struct AIProviderControls: View {
    @Bindable var connection: AIConnectionController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Обработка текста", selection: $connection.provider) {
                ForEach(connection.agents) { agent in
                    Text(providerTitle(agent)).tag(agent.provider)
                        .disabled(agent.provider != .openRouter && !agent.isAvailable)
                }
            }

            Picker("Модель", selection: $connection.modelID) {
                ForEach(modelChoices) { model in
                    Text(model.title).tag(model.id)
                }
            }
            .disabled(connection.models.isEmpty)

            HStack(spacing: 6) {
                if connection.isRefreshing {
                    ProgressView().controlSize(.mini)
                    Text("Ищу установленные агенты и модели…")
                } else {
                    Image(
                        systemName: selectedAgent?.isAvailable == true
                            ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(selectedAgent?.isAvailable == true ? .green : Theme.danger)
                    Text(statusText)
                    Spacer()
                    Button("Обновить") { connection.refreshAgents(force: true) }
                        .buttonStyle(.link)
                }
            }
            .typeStyle(.micro)
            .foregroundStyle(Theme.textSecondary)
        }
    }

    private var selectedAgent: AIAgentAvailability? {
        connection.agents.first { $0.provider == connection.provider }
    }

    private var modelChoices: [AIModelOption] {
        if connection.models.contains(where: { $0.id == connection.modelID }) {
            return connection.models
        }
        return [AIModelOption(id: connection.modelID)] + connection.models
    }

    private func providerTitle(_ agent: AIAgentAvailability) -> String {
        guard agent.provider != .openRouter, !agent.isAvailable else { return agent.provider.title }
        return "\(agent.provider.title) — не найден"
    }

    private var statusText: String {
        guard let selectedAgent else { return "Проверяю доступность…" }
        if let message = selectedAgent.message { return message }
        if selectedAgent.provider == .openRouter { return "Доступен по ключу OpenRouter" }
        return "\(selectedAgent.provider.title) готов · моделей: \(selectedAgent.models.count)"
    }
}

struct CLIAgentPrivacyNotice: View {
    let provider: AIProvider

    var body: some View {
        Label(
            "Агент получает только текст расшифровки с таймкодами. Звук, видео и пути файлов остаются на Mac. Текст обрабатывается через аккаунт, подключённый в \(provider.title).",
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

struct AIReasoningPicker: View {
    @Bindable var connection: AIConnectionController

    var body: some View {
        Picker("Размышления", selection: $connection.reasoningChoice) {
            ForEach(connection.reasoningOptions) { choice in
                Text(choice.title).tag(choice)
            }
        }
    }
}
