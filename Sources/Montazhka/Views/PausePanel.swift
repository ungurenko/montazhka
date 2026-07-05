import SwiftUI

/// Панель поиска пауз: настройки, список найденного, вырезка.
struct PausePanel: View {
    @ObservedObject var controller: EditorController
    @State private var settings = DetectionSettings()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Поиск пауз")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button {
                    withAnimation { controller.showPausePanel = false }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.textSecondary.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        settingsBlock
                        detectButton
                        if !controller.candidates.isEmpty {
                            resultsBlock
                                .id("results")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
                .onChange(of: controller.candidates.count) { _, count in
                    if count > 0 {
                        withAnimation { proxy.scrollTo("results", anchor: .top) }
                    }
                }
            }

            if !controller.candidates.isEmpty {
                cutBar
            }
        }
        .cardStyle()
        .onAppear { settings = controller.project.detection }
        .onChange(of: settings) { _, new in
            controller.updateDetectionSettings(new)
        }
    }

    // MARK: - Настройки

    private var settingsBlock: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingSlider(
                title: "Чувствительность",
                explain: "Что тише этого уровня — считается тишиной",
                value: $settings.thresholdDB,
                range: -60...(-20), step: 1,
                display: { "\(Int($0)) дБ" }
            )
            SettingSlider(
                title: "Минимальная пауза",
                explain: "Короче — не трогаем, это обычная речь",
                value: $settings.minPauseDuration,
                range: 0.3...3.0, step: 0.1,
                display: { String(format: "%.1f сек", $0) }
            )
            SettingSlider(
                title: "Воздух по краям",
                explain: "Сколько тишины оставить, чтобы не резало слух",
                value: $settings.paddingMS,
                range: 0...500, step: 25,
                display: { "\(Int($0)) мс" }
            )
        }
    }

    private var detectButton: some View {
        Button {
            controller.detectPauses()
        } label: {
            HStack {
                if controller.isDetecting {
                    ProgressView().controlSize(.small)
                    Text("Слушаю запись…")
                } else {
                    Image(systemName: "waveform.badge.magnifyingglass")
                    Text("Найти паузы")
                }
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.accent)
        .disabled(controller.isDetecting || controller.project.clips.isEmpty)
    }

    // MARK: - Результаты

    private var resultsBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            let enabled = controller.candidates.filter(\.enabled)
            let saved = enabled.reduce(0.0) { $0 + $1.duration }

            HStack {
                Text("Найдено: \(controller.candidates.count)")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button(enabled.count == controller.candidates.count ? "Снять все" : "Выбрать все") {
                    controller.setAllCandidates(enabled: enabled.count != controller.candidates.count)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.accent)
            }
            Text("Видео станет короче на \(TimeFormat.spoken(saved))")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)

            VStack(spacing: 6) {
                ForEach(Array(controller.candidates.enumerated()), id: \.element.id) { index, candidate in
                    CandidateRow(index: index + 1, candidate: candidate, controller: controller)
                }
            }
        }
    }

    private var cutBar: some View {
        VStack(spacing: 8) {
            Divider()
            let count = controller.candidates.filter(\.enabled).count
            Button {
                controller.cutEnabledCandidates()
            } label: {
                Label("Вырезать выбранные (\(count))", systemImage: "scissors")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.pauseHighlight)
            .disabled(count == 0)

            Button("Убрать подсветку") {
                controller.candidates = []
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }
}

// MARK: - Строка с паузой

private struct CandidateRow: View {
    let index: Int
    let candidate: PauseCandidate
    let controller: EditorController

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { candidate.enabled },
                set: { _ in controller.toggleCandidate(candidate.id) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 1) {
                Text("№\(index) · \(TimeFormat.compact(candidate.start))")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                Text(String(format: "%.1f сек тишины", candidate.duration))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer()

            Button {
                controller.previewCandidate(candidate)
            } label: {
                Image(systemName: "play.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .help("Послушать это место")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                .fill(candidate.enabled ? Theme.pauseHighlight.opacity(0.08) : Color.black.opacity(0.02))
        )
    }
}

// MARK: - Слайдер с подписью

private struct SettingSlider: View {
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
