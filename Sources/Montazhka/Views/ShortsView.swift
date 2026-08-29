@preconcurrency import AVFoundation
import AppKit
import SwiftUI

/// Экран нарезки на shorts: слева плеер, справа панель с настройками,
/// ходом анализа и кандидатами.
struct ShortsView: View {
    @Environment(AppModel.self) private var app
    @Bindable var controller: ShortsController
    @State private var keyInput = ""
    @State private var replacingKey = false
    @State private var keyMonitor: LocalEventMonitor?
    @State private var playerVideoSize = CGSize.zero
    @State private var showExportOptions = false

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
                    .frame(width: 340)
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
        HStack(spacing: 12) {
            Button {
                app.closeShorts()
            } label: {
                Label("Назад", systemImage: "chevron.left")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .disabled(app.isProjectOperationInProgress)
            .accessibilityIdentifier("shorts.back")

            VStack(alignment: .leading, spacing: Theme.Spacing.compact) {
                Text("Нарезка на shorts")
                    .font(.system(size: Theme.TypeScale.sectionTitle, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("\(controller.fileName) · \(TimeFormat.compact(controller.sourceDuration)) · русская речь")
                    .font(.system(size: Theme.TypeScale.helper))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.leading, 84)  // место под «светофор» окна
        .padding(.trailing, 16)
        .frame(height: 56)
    }

    // MARK: - Плеер

    private var playerArea: some View {
        ZStack {
            Color.black
            Button {
                controller.togglePlay()
            } label: {
                PlayerLayerView(player: controller.player) { size in
                    guard
                        abs(size.width - playerVideoSize.width) > 0.5
                            || abs(size.height - playerVideoSize.height) > 0.5
                    else { return }
                    playerVideoSize = size
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(controller.isPlaying ? "Поставить просмотр на паузу" : "Воспроизвести просмотр")
            .accessibilityIdentifier("shorts.player")
            if let subtitle = controller.currentPreviewSubtitle {
                ShortsSubtitleOverlayView(
                    subtitle: subtitle,
                    presentationSize: playerVideoSize)
            }
            if let error = controller.prepareError ?? controller.previewError {
                VStack(spacing: Theme.Spacing.small) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.system(size: 13))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.white)
                .padding(24)
            } else if controller.candidates.isEmpty && !controller.status.isWorking {
                VStack(spacing: Theme.Spacing.small) {
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.system(size: 32, weight: .light))
                    Text("Выбери параметры справа\nи нажми «Найти моменты»")
                        .multilineTextAlignment(.center)
                        .font(.system(size: Theme.TypeScale.body))
                }
                .foregroundStyle(.white.opacity(0.55))
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
                    .font(.system(size: 12, weight: .medium))
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
                    .font(.system(size: Theme.TypeScale.helper))
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
                    .font(.system(size: Theme.TypeScale.helper, weight: .medium))
                    .foregroundStyle(Theme.danger)
            }

            if let error = controller.prepareError {
                errorLabel(error)
            } else if case .failed(let message) = controller.status {
                errorLabel(message)
            } else if !controller.analysisWarnings.isEmpty {
                analysisWarningBlock
            } else if controller.status == .ready && controller.candidates.isEmpty {
                Label(
                    "Не нашёл моментов, из которых получается сильный ролик.",
                    systemImage: "checkmark.seal.fill"
                )
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                controller.analyze()
            } label: {
                Label(analyzeButtonTitle, systemImage: "sparkles")
                    .font(.system(size: Theme.TypeScale.body, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .disabled(analyzeDisabled)
            .accessibilityIdentifier("shorts.analyze")

            if controller.aiConnection.provider == .openRouter {
                Link("Получить ключ OpenRouter", destination: URL(string: "https://openrouter.ai/settings/keys")!)
                    .font(.system(size: Theme.TypeScale.helper, weight: .medium))
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

    private func errorLabel(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: Theme.TypeScale.helper))
            .foregroundStyle(Theme.danger)
            .fixedSize(horizontal: false, vertical: true)
            .padding(Theme.Spacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.danger.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
    }

    // MARK: - Прогресс анализа

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            ProgressView(value: progressValue)
                .progressViewStyle(.linear)
                .tint(Theme.accent)
            Text(statusTitle)
                .font(.system(size: Theme.TypeScale.helper))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Отменить анализ") { controller.cancelAnalysis() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(12)
        .background(Theme.accent.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
    }

    private var progressValue: Double? {
        switch controller.status {
        case .preparingModel(let value): return value.map { $0 * 0.12 }
        case .transcribing(let value): return 0.12 + 0.38 * (value ?? 0)
        case .mapping(let done, let total):
            guard total > 0 else { return nil }
            return 0.50 + 0.20 * Double(done) / Double(total)
        case .searching(let done, let total):
            guard total > 0 else { return nil }
            return 0.70 + 0.18 * Double(done) / Double(total)
        case .ranking: return 0.90
        case .verifying: return 0.96
        default: return nil
        }
    }

    private var statusTitle: String {
        switch controller.status {
        case .preparingModel: return "Готовлю локальную модель — в первый раз загружается около 460 МБ"
        case .transcribing: return "Расшифровываю речь"
        case .mapping(let done, let total): return "Составляю карту видео: окно \(done + 1) из \(total)"
        case .searching(let done, let total): return "Ищу сильные моменты: окно \(done + 1) из \(total)"
        case .ranking: return "Отбираю и ранжирую лучшие моменты"
        case .verifying: return "Проверяю выбранные моменты тестом холодного зрителя"
        default: return ""
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
                .font(.system(size: Theme.TypeScale.helper, weight: .semibold))
                Spacer()
                Button("Искать заново") { controller.analyze() }
                    .buttonStyle(.link)
                    .font(.system(size: Theme.TypeScale.helper))
                    .disabled(controller.openRouterKeyStatus != .saved)
            }
            ForEach(controller.candidates) { candidate in
                candidateCard(candidate)
            }
        }
    }

    private var analysisWarningBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(controller.analysisWarnings.enumerated()), id: \.offset) { _, warning in
                Label(warning.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: Theme.TypeScale.helper))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Повторить анализ") { controller.analyze() }
                .buttonStyle(.link)
                .font(.system(size: Theme.TypeScale.helper, weight: .medium))
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
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(2)
                    if !candidate.hook.isEmpty {
                        Text("«\(candidate.hook)…»")
                            .font(.system(size: Theme.TypeScale.helper, weight: .medium))
                            .italic()
                            .foregroundStyle(Theme.accent)
                            .lineLimit(1)
                    }
                    Text(candidate.excerpt)
                        .font(.system(size: Theme.TypeScale.helper))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(3)
                }
            }
            HStack {
                Text(TimeFormat.compact(candidate.duration))
                    .font(.system(size: Theme.TypeScale.helper, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.background)
                    .clipShape(Capsule())
                if !candidate.pattern.isEmpty {
                    Text(candidate.pattern)
                        .font(.system(size: Theme.TypeScale.helper, weight: .medium))
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
                        .font(.system(size: Theme.TypeScale.helper, weight: .medium))
                }
                .buttonStyle(.link)
            }

            DisclosureGroup("Почему выбран") {
                VStack(alignment: .leading, spacing: Theme.Spacing.compact) {
                    Text(candidate.reason)
                        .font(.system(size: Theme.TypeScale.helper))
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
            .font(.system(size: Theme.TypeScale.helper, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
        }
        .padding(Theme.Spacing.small)
        .rowSurfaceStyle(selected: candidate.enabled)
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
                            .font(.system(size: Theme.TypeScale.helper, weight: .semibold))
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
                        .font(.system(size: Theme.TypeScale.helper))
                    }
                }
            case .exporting(let done, let total, let progress):
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: (Double(done) + progress) / Double(max(1, total)))
                        .progressViewStyle(.linear)
                        .tint(Theme.accent)
                    HStack {
                        Text("Сохраняю ролик \(min(done + 1, total)) из \(total)…")
                            .font(.system(size: Theme.TypeScale.helper))
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Button("Отменить") { controller.cancelExport() }
                            .buttonStyle(.link)
                            .font(.system(size: Theme.TypeScale.helper))
                    }
                }
            case .done(let folder):
                VStack(alignment: .leading, spacing: 8) {
                    Label("Ролики сохранены", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.green)
                    HStack {
                        Button("Показать в Finder") { controller.revealFolder(folder) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Button("Сохранить ещё раз") { controller.chooseFolderAndExport() }
                            .buttonStyle(.link)
                            .font(.system(size: Theme.TypeScale.helper))
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
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            DisclosureGroup(isExpanded: $showExportOptions) {
                appearanceControls
                    .padding(.top, Theme.Spacing.small)
            } label: {
                VStack(alignment: .leading, spacing: Theme.Spacing.compact) {
                    Text("Оформление")
                        .font(.system(size: Theme.TypeScale.body, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("\(controller.frameMode.title) · \(controller.quality.title)")
                        .font(.system(size: Theme.TypeScale.helper))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .accessibilityIdentifier("shorts.appearance")

            Divider()

            HStack(spacing: Theme.Spacing.small) {
                Text("Выбрано: \(controller.selectedCount)")
                    .font(.system(size: Theme.TypeScale.helper, weight: .medium))
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
    }

    private var appearanceControls: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Toggle(isOn: $controller.subtitlesEnabled) {
                VStack(alignment: .leading, spacing: Theme.Spacing.compact) {
                    Text("Автоматические субтитры")
                        .font(.system(size: Theme.TypeScale.body, weight: .medium))
                    Text("В просмотре и сохранённых роликах")
                        .font(.system(size: Theme.TypeScale.helper))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .toggleStyle(.switch)
            .accessibilityIdentifier("shorts.subtitles")

            if controller.subtitlesEnabled {
                HStack(spacing: 8) {
                    Text("Стиль")
                        .font(.system(size: Theme.TypeScale.helper, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    Picker("Стиль субтитров", selection: $controller.subtitleStyle) {
                        ForEach(ShortsSubtitleStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("shorts.subtitleStyle")
                }

                HStack(spacing: 8) {
                    Text("Размер")
                        .font(.system(size: Theme.TypeScale.helper, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    Picker("Размер субтитров", selection: $controller.subtitleSize) {
                        ForEach(ShortsSubtitleSize.allCases) { size in
                            Text(size.title).tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("shorts.subtitleSize")
                }
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Text("Формат кадра")
                    .font(.system(size: Theme.TypeScale.helper, weight: .medium))
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
                    .font(.system(size: Theme.TypeScale.helper))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if controller.frameMode == .verticalFit {
                HStack(spacing: 8) {
                    Text("Фон")
                        .font(.system(size: Theme.TypeScale.helper, weight: .medium))
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
                    .font(.system(size: Theme.TypeScale.helper, weight: .medium))
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
                .font(.system(size: Theme.TypeScale.time, weight: .medium, design: .monospaced))
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

            Text(TimeFormat.short(controller.sourceDuration))
                .font(.system(size: Theme.TypeScale.time, weight: .medium, design: .monospaced))
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
