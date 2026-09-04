@preconcurrency import AVFoundation
import AppKit
import SwiftUI

/// Экран нарезки на shorts: слева плеер, справа панель с настройками,
/// ходом анализа и кандидатами.
struct ShortsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var controller: ShortsController
    @State private var keyInput = ""
    @State private var replacingKey = false
    @State private var keyMonitor: LocalEventMonitor?
    @State private var showExportOptions = false
    @State private var subtitleSettingsExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            HStack(spacing: Theme.Spacing.medium) {
                VStack(spacing: 0) {
                    playerArea
                    Divider()
                    ShortsTransportBar(controller: controller)
                }
                .cardStyle()
                sidePanel
                    .frame(width: Theme.Metrics.inspectorWidth)
            }
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.bottom, Theme.Spacing.medium)
        }
        .background(Theme.background)
        .task {
            controller.prepare()
            controller.aiConnection.refreshAgents()
            controller.aiConnection.refreshReasoningOptions()
        }
        .onAppear(perform: installKeyMonitor)
        .onDisappear(perform: removeKeyMonitor)
    }

    // MARK: - Верхняя панель

    private var topBar: some View {
        TopBar(
            back: TopBarBackButton(
                title: "Назад",
                accessibilityIdentifier: "shorts.back",
                isDisabled: app.isProjectOperationInProgress,
                action: { app.closeShorts() })
        ) {
            TopBarTitle(
                title: "Нарезка на shorts",
                subtitle:
                    "\(controller.fileName) · \(TimeFormat.compact(controller.sourceDuration)) · русская речь")
        }
    }

    // MARK: - Плеер

    private var playerArea: some View {
        ZStack {
            Color.black
            Button {
                controller.togglePlay()
            } label: {
                PlayerLayerView(player: controller.player)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(controller.isPlaying ? "Поставить просмотр на паузу" : "Воспроизвести просмотр")
            .accessibilityIdentifier("shorts.player")
            if let subtitle = controller.currentPreviewSubtitle {
                ShortsSubtitleOverlayView(
                    subtitle: subtitle,
                    frameSize: controller.previewFrameSize)
            }
            if let error = controller.prepareError ?? controller.previewError {
                EmptyStateView(
                    systemImage: "exclamationmark.triangle.fill",
                    title: error.what,
                    message: error.hint,
                    appearance: .onMedia)
            } else if controller.candidates.isEmpty && !controller.status.isWorking {
                EmptyStateView(
                    systemImage: "sparkles.rectangle.stack",
                    title: "Готов искать сильные моменты",
                    message: "Выбери параметры справа и нажми «Найти моменты»",
                    appearance: .onMedia)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Боковая панель

    private var sidePanel: some View {
        InspectorPanel(
            title: "Короткие ролики",
            systemImage: "sparkles.rectangle.stack",
            accessibilityIdentifier: "shorts.inspector",
            close: nil
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if controller.status.isWorking {
                        progressSection
                    } else if !controller.candidates.isEmpty {
                        resultsSection
                        appearanceSection
                    } else {
                        settingsSection
                    }
                }
                .padding(.horizontal, Theme.Spacing.medium)
                .padding(.bottom, Theme.Spacing.medium)
            }
            .background(Theme.surfaceMuted)
        } footer: {
            if !controller.candidates.isEmpty {
                exportBar
            }
        }
    }

    // MARK: - Настройки и запуск

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Text("Сколько роликов найти")
                    .typeStyle(.helperEmphasis)
                    .foregroundStyle(Theme.textPrimary)
                Picker("Сколько роликов", selection: $controller.count) {
                    ForEach(ShortsCount.allCases) { count in
                        Text(count.title).tag(count)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            AIProviderControls(
                connection: controller.aiConnection)

            AIReasoningPicker(connection: controller.aiConnection)
            if controller.aiConnection.reasoningOptions.count > 1 {
                Text("Глубина «размышлений» модели. Выше уровень — вдумчивее отбор, но дольше и дороже анализ.")
                    .typeStyle(.helper)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if controller.aiConnection.provider == .openRouter {
                OpenRouterKeyControls(
                    controller: controller,
                    keyInput: $keyInput,
                    replacingKey: $replacingKey
                )
            } else {
                CLIAgentPrivacyNotice(provider: controller.aiConnection.provider)
            }

            if !SmartEditPlatform.isSupported {
                Label("Нарезка доступна на Mac с Apple Silicon.", systemImage: "cpu")
                    .typeStyle(.helperEmphasis)
                    .foregroundStyle(Theme.danger)
            }

            if let error = controller.prepareError {
                errorLabel(error)
            } else if case .failed(let message) = controller.status {
                errorLabel(message)
                usageLine
            } else if !controller.analysisWarnings.isEmpty {
                analysisWarningBlock
            } else if controller.status == .ready && controller.candidates.isEmpty {
                Label(
                    "Не нашёл моментов, из которых получается сильный ролик.",
                    systemImage: "checkmark.seal.fill"
                )
                .typeStyle(.helperEmphasis)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                controller.analyze()
            } label: {
                Label(analyzeButtonTitle, systemImage: "sparkles")
                    .typeStyle(.bodyEmphasis)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .disabled(analyzeDisabled)
            .accessibilityIdentifier("shorts.analyze")

            if controller.aiConnection.provider == .openRouter {
                Link("Получить ключ OpenRouter", destination: URL(string: "https://openrouter.ai/settings/keys")!)
                    .typeStyle(.helperEmphasis)
            }
        }
    }

    private var analyzeButtonTitle: String {
        if case .failed = controller.status { return "Повторить анализ" }
        if controller.status == .ready { return "Искать ещё раз" }
        return "Найти моменты"
    }

    private var analyzeDisabled: Bool {
        !controller.aiConnection.isReady || controller.prepareError != nil
            || controller.sourceDuration < ShortsLimits.minSourceDuration || !SmartEditPlatform.isSupported
    }

    private func errorLabel(_ error: UserFacingError) -> some View {
        StatusBanner(error: error)
    }

    // MARK: - Прогресс анализа

    @ViewBuilder
    private var progressSection: some View {
        if let activity = controller.activity.activity(.shortsAnalysis) {
            ActivityBlock(activity: activity) { controller.cancelAnalysis() }
        }
    }

    // MARK: - Субтитры

    private var subtitlePresets: some View {
        HStack(spacing: Theme.Spacing.small) {
            ForEach(ShortsSubtitlePreset.allCases) { preset in
                Button {
                    controller.subtitlePreset = preset
                } label: {
                    subtitlePresetCard(preset)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Образ субтитров: \(preset.title)")
            }
        }
        .accessibilityIdentifier("shorts.subtitlePresets")
    }

    private func subtitlePresetCard(_ preset: ShortsSubtitlePreset) -> some View {
        let appearance = preset.appearance
        let isSelected = controller.subtitlePreset == preset
        return VStack(spacing: Theme.Spacing.compact) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.85))
                Text("Аа")
                    .font(Font(appearance.font.font(ofSize: 15)))
                    .foregroundStyle(Color(appearance.textColor.nsColor))
                    .shadow(
                        color: appearance.background == .shadow ? .black : .clear,
                        radius: 1, x: 0, y: 1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background {
                        if appearance.background == .plate {
                            RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.72))
                        }
                    }
            }
            .frame(height: 40)
            Text(preset.title)
                .typeStyle(.micro)
                .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Theme.accent : .clear, lineWidth: 2)
                .padding(.bottom, 18)
        }
    }

    private var subtitleFontRow: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text("Шрифт")
                .typeStyle(.helperEmphasis)
                .foregroundStyle(Theme.textSecondary)
            HStack(spacing: Theme.Spacing.small) {
                ForEach(ShortsSubtitleFont.allCases) { font in
                    Button {
                        controller.subtitleFont = font
                    } label: {
                        Text("Аа")
                            .font(Font(font.font(ofSize: 14)))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Theme.Spacing.small)
                            .background {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(
                                        controller.subtitleFont == font
                                            ? Theme.accent.opacity(0.16) : Color.gray.opacity(0.12))
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Шрифт субтитров: \(font.title)")
                }
            }
        }
        .accessibilityIdentifier("shorts.subtitleFont")
    }

    private var subtitleSizeRow: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text("Размер")
                .typeStyle(.helperEmphasis)
                .foregroundStyle(Theme.textSecondary)
            Picker("Размер субтитров", selection: $controller.subtitleSize) {
                ForEach(ShortsSubtitleSize.allCases) { size in
                    Text(size.title).tag(size)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("shorts.subtitleSize")
        }
    }

    private func subtitleColorRow(
        title: String,
        selection: Binding<ShortsSubtitleColor>,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text(title)
                .typeStyle(.helperEmphasis)
                .foregroundStyle(Theme.textSecondary)
            HStack(spacing: Theme.Spacing.small) {
                ForEach(ShortsSubtitleColor.allCases) { color in
                    Button {
                        selection.wrappedValue = color
                    } label: {
                        Circle()
                            .fill(Color(color.nsColor))
                            .frame(width: 20, height: 20)
                            .overlay {
                                Circle().strokeBorder(
                                    selection.wrappedValue == color
                                        ? Theme.accent : Color.gray.opacity(0.35),
                                    lineWidth: selection.wrappedValue == color ? 2.5 : 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(title): \(color.title)")
                }
            }
        }
        .accessibilityIdentifier(identifier)
    }

    private var subtitleBackgroundRow: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text("Подложка")
                .typeStyle(.helperEmphasis)
                .foregroundStyle(Theme.textSecondary)
            Picker("Подложка субтитров", selection: $controller.subtitleBackground) {
                ForEach(ShortsSubtitleBackground.allCases) { background in
                    Text(background.title).tag(background)
                }
            }
            .labelsHidden()
            .accessibilityIdentifier("shorts.subtitleBackground")
        }
    }

    private var subtitlePositionRow: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text("Положение")
                .typeStyle(.helperEmphasis)
                .foregroundStyle(Theme.textSecondary)
            Picker("Положение субтитров", selection: $controller.subtitlePosition) {
                ForEach(ShortsSubtitlePosition.allCases) { position in
                    Text(position.title).tag(position)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("shorts.subtitlePosition")
        }
    }

    /// Во что обошёлся последний запуск. Молчит, когда запросов не было —
    /// например, результат взяли из кэша.
    @ViewBuilder
    private var usageLine: some View {
        if let usage = controller.lastUsage.summary {
            Text("Расход: \(usage)")
                .typeStyle(.helper)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: - Результаты

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !controller.analysisWarnings.isEmpty {
                analysisWarningBlock
            }
            HStack {
                Text(
                    "\(controller.candidates.count) \(Plurals.candidates(controller.candidates.count)) · выбрано \(controller.selectedCount)"
                )
                .typeStyle(.helperEmphasis)
                Spacer()
                Button("Искать заново") { controller.analyze() }
                    .buttonStyle(.link)
                    .typeStyle(.helper)
                    .disabled(controller.openRouterKeyStatus != .saved)
            }
            usageLine
            ForEach(controller.candidates) { candidate in
                candidateCard(candidate)
            }
        }
    }

    private var analysisWarningBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(controller.analysisWarnings.enumerated()), id: \.offset) { _, warning in
                Label(warning.message, systemImage: "exclamationmark.triangle.fill")
                    .typeStyle(.helper)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Повторить анализ") { controller.analyze() }
                .buttonStyle(.link)
                .typeStyle(.helperEmphasis)
                .disabled(controller.openRouterKeyStatus != .saved)
        }
        .padding(Theme.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
        .accessibilityIdentifier("shorts.analysisWarnings")
    }

    private func candidateCard(_ candidate: ShortCandidate) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Toggle(
                isOn: Binding(
                    get: { controller.candidates.first(where: { $0.id == candidate.id })?.enabled ?? false },
                    set: { _ in controller.toggleCandidate(candidate.id) }
                )
            ) {
                VStack(alignment: .leading, spacing: Theme.Spacing.compact) {
                    Text("\(candidate.rank). \(candidate.title)")
                        .typeStyle(.helperEmphasis)
                        .lineLimit(2)
                    if !candidate.hook.isEmpty {
                        Text("«\(candidate.hook)…»")
                            .typeStyle(.helperEmphasis)
                            .italic()
                            .foregroundStyle(Theme.accent)
                            .lineLimit(1)
                    }
                    Text(candidate.excerpt)
                        .typeStyle(.helper)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(3)
                }
            }
            HStack {
                Text(durationLabel(for: candidate))
                    .font(.system(size: Theme.TypeScale.helper, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.background)
                    .clipShape(Capsule())
                if !candidate.pattern.isEmpty {
                    Text(candidate.pattern)
                        .typeStyle(.helperEmphasis)
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.accent.opacity(0.12))
                        .clipShape(Capsule())
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    controller.preview(candidate)
                } label: {
                    Label("Просмотр", systemImage: "play.circle")
                        .typeStyle(.helperEmphasis)
                }
                .buttonStyle(.link)
            }

            DisclosureGroup("Почему выбран") {
                VStack(alignment: .leading, spacing: Theme.Spacing.compact) {
                    Text(candidate.reason)
                        .typeStyle(.helper)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(
                        "Хук \(candidate.hookScore) · Отдельно \(candidate.standaloneScore) · Польза \(candidate.payoffScore) · Темп \(candidate.pacingScore)"
                    )
                    .font(.system(size: Theme.TypeScale.helper, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                }
                .padding(.top, Theme.Spacing.compact)
            }
            .typeStyle(.helperEmphasis)
            .foregroundStyle(Theme.textSecondary)
        }
        .padding(Theme.Spacing.small)
        .rowSurfaceStyle(selected: candidate.enabled)
    }

    /// «0:45 → 0:38», когда вырезание пауз реально укоротило ролик.
    private func durationLabel(for candidate: ShortCandidate) -> String {
        let map = controller.timeMap(for: candidate)
        guard map.removedDuration >= 0.5 else {
            return TimeFormat.compact(candidate.duration)
        }
        return "\(TimeFormat.compact(candidate.duration)) → \(TimeFormat.compact(map.outputDuration))"
    }

    // MARK: - Экспорт

    private var exportBar: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            switch controller.exportState {
            case .idle:
                exportControls
            case .failed(let message, let completed, let total, let folder):
                VStack(alignment: .leading, spacing: 8) {
                    errorLabel(message)
                    if completed > 0 {
                        Text("Сохранено \(completed) из \(total)")
                            .typeStyle(.helperEmphasis)
                            .foregroundStyle(Theme.textPrimary)
                    }
                    HStack {
                        Button("Показать в Finder") { controller.revealFolder(folder) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Button(completed > 0 ? "Сохранить оставшиеся" : "Повторить экспорт") {
                            controller.retryRemainingExport()
                        }
                        .buttonStyle(.link)
                        .typeStyle(.helper)
                    }
                }
            case .exporting:
                if let activity = controller.activity.activity(.shortsExport) {
                    ActivityBlock(activity: activity) { controller.cancelExport() }
                }
            case .done(let folder):
                VStack(alignment: .leading, spacing: 8) {
                    Label("Ролики сохранены", systemImage: "checkmark.circle.fill")
                        .typeStyle(.helperEmphasis)
                        .foregroundStyle(.green)
                    HStack {
                        Button("Показать в Finder") { controller.revealFolder(folder) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Button("Сохранить ещё раз") { controller.chooseFolderAndExport() }
                            .buttonStyle(.link)
                            .typeStyle(.helper)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
        .background(Theme.card)
    }

    private var exportControls: some View {
        HStack(spacing: Theme.Spacing.small) {
            Text("Выбрано: \(controller.selectedCount)")
                .typeStyle(.helperEmphasis)
                .foregroundStyle(Theme.textSecondary)

            Spacer()

            Button {
                controller.chooseFolderAndExport()
            } label: {
                Label("Сохранить", systemImage: "square.and.arrow.down")
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .disabled(controller.selectedCount == 0)
        }
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Divider()

            Button {
                withAnimation(
                    reduceMotion ? .linear(duration: 0.12) : .easeInOut(duration: 0.2)
                ) {
                    showExportOptions.toggle()
                }
            } label: {
                HStack(spacing: Theme.Spacing.small) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.compact) {
                        Text("Оформление")
                            .typeStyle(.bodyEmphasis)
                            .foregroundStyle(Theme.textPrimary)
                        Text("\(controller.frameMode.title) · \(controller.quality.title)")
                            .typeStyle(.helper)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Image(systemName: showExportOptions ? "chevron.down" : "chevron.right")
                        .typeStyle(.helperEmphasis)
                        .foregroundStyle(Theme.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Оформление")
            .accessibilityIdentifier("shorts.appearance")
            .accessibilityValue(showExportOptions ? "Развёрнуто" : "Свёрнуто")

            if showExportOptions {
                appearanceControls
                    .padding(.top, Theme.Spacing.small)
                    .transition(.opacity)
            }
        }
    }

    private var appearanceControls: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Toggle(isOn: $controller.trimPauses) {
                VStack(alignment: .leading, spacing: Theme.Spacing.compact) {
                    Text("Убрать паузы")
                        .typeStyle(.bodyEmphasis)
                    Text("Вырезает вдохи и молчание внутри ролика")
                        .typeStyle(.helper)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .toggleStyle(.switch)
            .accessibilityIdentifier("shorts.trimPauses")

            Toggle(isOn: $controller.subtitlesEnabled) {
                VStack(alignment: .leading, spacing: Theme.Spacing.compact) {
                    Text("Автоматические субтитры")
                        .typeStyle(.bodyEmphasis)
                    Text("В просмотре и сохранённых роликах")
                        .typeStyle(.helper)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .toggleStyle(.switch)
            .accessibilityIdentifier("shorts.subtitles")

            if controller.subtitlesEnabled {
                subtitlePresets

                DisclosureGroup(isExpanded: $subtitleSettingsExpanded) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.snug) {
                        subtitleFontRow
                        subtitleSizeRow
                        subtitleColorRow(
                            title: "Цвет текста",
                            selection: $controller.subtitleTextColor,
                            identifier: "shorts.subtitleTextColor")
                        subtitleColorRow(
                            title: "Активное слово",
                            selection: $controller.subtitleHighlightColor,
                            identifier: "shorts.subtitleHighlightColor")
                        subtitleBackgroundRow
                        subtitlePositionRow
                        Toggle(isOn: $controller.subtitleHighlight) {
                            Text("Подсвечивать звучащее слово")
                                .typeStyle(.helper)
                        }
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("shorts.subtitleHighlight")
                    }
                    .padding(.top, Theme.Spacing.snug)
                } label: {
                    Text("Настроить")
                        .typeStyle(.helperEmphasis)
                        .foregroundStyle(Theme.textSecondary)
                }
                .accessibilityIdentifier("shorts.subtitleSettings")
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Text("Формат кадра")
                    .typeStyle(.helperEmphasis)
                    .foregroundStyle(Theme.textSecondary)
                Picker("Формат кадра", selection: $controller.frameMode) {
                    ForEach(ShortsFrameMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("shorts.frameMode")
                Text(controller.frameMode.subtitle)
                    .typeStyle(.helper)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if controller.frameMode == .verticalFit {
                HStack(spacing: 8) {
                    Text("Фон")
                        .typeStyle(.helperEmphasis)
                        .foregroundStyle(Theme.textSecondary)
                    Picker("Цвет фона", selection: $controller.canvasColor) {
                        ForEach(ShortsCanvasColor.allCases) { color in
                            Text(color.title).tag(color)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("shorts.canvasColor")
                }
            }

            HStack(spacing: Theme.Spacing.small) {
                Text("Качество")
                    .typeStyle(.helperEmphasis)
                    .foregroundStyle(Theme.textSecondary)
                Picker("Качество", selection: $controller.quality) {
                    ForEach(ExportQuality.allCases) { quality in
                        Text(quality.title).tag(quality)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Клавиатура

    /// Пробел ловим сами, а не пунктом меню: перехватчик пропускает событие
    /// дальше, когда курсор стоит в текстовом поле, — иначе пробел нельзя было
    /// бы набрать в поле ключа OpenRouter.
    private func installKeyMonitor() {
        removeKeyMonitor()
        let controller = self.controller
        let monitor = LocalEventMonitor()
        monitor.install(matching: .keyDown) { event in
            if NSApp.keyWindow?.firstResponder is NSTextView { return event }
            if event.modifierFlags.contains(.command) { return event }
            if event.keyCode == 49 {  // пробел
                controller.togglePlay()
                return nil
            }
            return event
        }
        keyMonitor = monitor
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            keyMonitor.remove()
            self.keyMonitor = nil
        }
    }
}

/// Частые обновления времени и Play/Pause ограничены этой маленькой панелью.
private struct ShortsTransportBar: View {
    var controller: ShortsController

    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Text(TimeFormat.short(controller.currentTime))
                .typeStyle(.time)
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 72, alignment: .leading)
                .accessibilityLabel("Текущая позиция")
                .accessibilityValue(TimeFormat.short(controller.currentTime))

            Spacer()

            Button {
                controller.togglePlay()
            } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Theme.accent)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Плей/пауза (пробел)")
            .accessibilityLabel(controller.isPlaying ? "Пауза" : "Воспроизвести")
            .accessibilityIdentifier("shorts.playPause")

            Spacer()

            Text(TimeFormat.short(controller.previewDuration))
                .typeStyle(.time)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 72, alignment: .trailing)
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
    }
}

/// Простые русские формы слов для счётчиков.
enum Plurals {
    static func candidates(_ count: Int) -> String {
        switch count % 10 {
        case 1 where count % 100 != 11: return "кандидат"
        case 2, 3, 4:
            return (12...14).contains(count % 100) ? "кандидатов" : "кандидата"
        default: return "кандидатов"
        }
    }
}
