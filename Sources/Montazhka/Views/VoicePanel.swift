import SwiftUI

/// Панель улучшения голоса: тумблер и три ползунка.
struct VoicePanel: View {
    @ObservedObject var controller: EditorController
    @State private var settings = VoiceEnhanceSettings()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Улучшение голоса")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button {
                    withAnimation { controller.showVoicePanel = false }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.textSecondary.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    toggleBlock
                    slidersBlock
                    statusBlock
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        .cardStyle()
        .onAppear { settings = controller.project.voiceEnhance }
        .onChange(of: settings) { _, new in
            controller.updateVoiceSettings(new)
        }
    }

    private var toggleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Улучшить голос", isOn: $settings.enabled)
                .toggleStyle(.switch)
                .tint(Theme.accent)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Text("Выравнивает громкость, приглушает фоновый шум и делает голос звонче. Слышно сразу в предпросмотре, в готовом видео будет так же.")
                .font(.system(size: 11))
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
        .disabled(!settings.enabled)
        .opacity(settings.enabled ? 1 : 0.5)
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
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
        }
    }
}
