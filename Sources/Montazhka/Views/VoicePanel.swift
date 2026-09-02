import SwiftUI

/// Панель улучшения голоса: тумблер и три ползунка.
struct VoicePanel: View {
    var controller: EditorController
    @State private var settings = VoiceEnhanceSettings()

    var body: some View {
        InspectorPanel(
            title: "Улучшение голоса",
            systemImage: "waveform.and.mic",
            accessibilityIdentifier: "editor.inspector.voice",
            close: { withAnimation { controller.activeInspector = nil } }
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                    toggleBlock
                    if settings.enabled { slidersBlock }
                    statusBlock
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .onAppear { settings = controller.project.voiceEnhance }
        .onChange(of: settings) { _, new in
            controller.updateVoiceSettings(new)
        }
    }

    private var toggleBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Toggle("Улучшить голос", isOn: $settings.enabled)
                .toggleStyle(.switch)
                .tint(Theme.accent)
                .font(.system(size: Theme.TypeScale.body, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(
                "Выравнивает громкость, приглушает шум и делает речь разборчивее. Результат слышно в предпросмотре."
            )
            .font(.system(size: Theme.TypeScale.helper))
            .foregroundStyle(Theme.textSecondary)
        }
    }

    private var slidersBlock: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingSlider(
                title: "Выравнивание громкости",
                explain: "Тихое подтягивает, слишком громкое приглушает",
                value: $settings.leveling,
                range: 0...100, step: 1,
                display: { "\(Int($0)) %" }
            )
            SettingSlider(
                title: "Чистка шума",
                explain: "Приглушает шипение и гул в паузах между фразами",
                value: $settings.noiseReduction,
                range: 0...100, step: 1,
                display: { "\(Int($0)) %" }
            )
            SettingSlider(
                title: "Звонкость",
                explain: "Делает голос чётче и разборчивее",
                value: $settings.presence,
                range: 0...100, step: 1,
                display: { "\(Int($0)) %" }
            )
        }
    }

    @ViewBuilder
    private var statusBlock: some View {
        switch controller.voiceStatus {
        case .idle:
            EmptyView()
        case .rendering(let done, let total):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(total > 1 ? "Обрабатываю звук… (\(done) из \(total))" : "Обрабатываю звук…")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
        case .failed(let error):
            StatusBanner(kind: .warning, error: error)
        }
    }
}
