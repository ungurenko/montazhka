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
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(display(value))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.accent)
            }
            Slider(value: $value, in: range, step: step)
                .controlSize(.small)
                .tint(Theme.accent)
            Text(explain)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
        }
    }
}
