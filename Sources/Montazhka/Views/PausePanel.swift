import SwiftUI

/// Панель поиска пауз: настройки, список найденного, вырезка.
struct PausePanel: View {
    var controller: EditorController
    @State private var settings = DetectionSettings()

    var body: some View {
        InspectorPanel(
            title: "Поиск пауз",
            systemImage: "waveform.badge.magnifyingglass",
            accessibilityIdentifier: "editor.inspector.pauses",
            close: { withAnimation { controller.activeInspector = nil } }
        ) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                        settingsBlock
                        detectButton
                        if !controller.candidates.isEmpty {
                            resultsBlock
                                .id("results")
                        } else if controller.hasPauseResult && !controller.isDetecting {
                            EmptyStateView(
                                systemImage: "waveform",
                                title: "Пауз не нашлось",
                                message:
                                    "Речь идёт без заметных остановок. Подними чувствительность "
                                    + "или уменьши минимальную паузу и поищи ещё раз.",
                                action: EmptyStateView.Action(
                                    title: "Искать снова",
                                    accessibilityIdentifier: "pauses.retry",
                                    perform: { controller.detectPauses() })
                            )
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.medium)
                    .padding(.bottom, Theme.Spacing.medium)
                }
                .onChange(of: controller.candidates.count) { _, count in
                    if count > 0 {
                        withAnimation { proxy.scrollTo("results", anchor: .top) }
                    }
                }
            }
        } footer: {
            if !controller.candidates.isEmpty {
                cutBar
            }
        }
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
            .typeStyle(.bodyEmphasis)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.accent)
        .disabled(controller.isDetecting || controller.project.clips.isEmpty)
    }

    // MARK: - Результаты

    private var resultsBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            let enabled = controller.candidates.filter(\.enabled)
            let saved = enabled.reduce(0.0) { $0 + $1.duration }

            HStack {
                Text("Найдено: \(controller.candidates.count)")
                    .typeStyle(.bodyEmphasis)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button(enabled.count == controller.candidates.count ? "Снять все" : "Выбрать все") {
                    controller.setAllCandidates(enabled: enabled.count != controller.candidates.count)
                }
                .buttonStyle(.plain)
                .typeStyle(.helper)
                .foregroundStyle(Theme.accent)
            }
            Text("Видео станет короче на \(TimeFormat.spoken(saved))")
                .typeStyle(.helper)
                .foregroundStyle(Theme.textSecondary)

            VStack(spacing: Theme.Spacing.small) {
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
                    .typeStyle(.bodyEmphasis)
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
            .typeStyle(.helper)
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
        SelectableRow(
            marker: .checkbox(
                Binding(
                    get: { candidate.enabled },
                    set: { _ in controller.toggleCandidate(candidate.id) })),
            title: "№\(index) · \(TimeFormat.compact(candidate.start))",
            titleStyle: .time,
            subtitle: String(format: "%.1f сек тишины", candidate.duration),
            isSelected: candidate.enabled,
            tint: Theme.pauseHighlight
        ) {
            IconButton(
                icon: "play.circle",
                help: "Послушать это место",
                size: .toolbar
            ) {
                controller.previewCandidate(candidate)
            }
            .foregroundStyle(Theme.accent)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
    }
}
