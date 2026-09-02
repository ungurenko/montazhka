import SwiftUI

/// Слайдер с подписью и пояснением — общий для панелей настроек.
struct SettingSlider: View {
    let title: String
    let explain: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let display: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .typeStyle(.bodyEmphasis)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(display(value))
                    .font(.system(size: Theme.TypeScale.helper, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.accent)
            }
            Slider(value: $value, in: range, step: step)
                .controlSize(.small)
                .tint(Theme.accent)
            Text(explain)
                .typeStyle(.helper)
                .foregroundStyle(Theme.textSecondary)
        }
    }
}
