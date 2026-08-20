import AVFoundation
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

    var body: some View {
        VStack(spacing: 0) {
            topBar
            HStack(spacing: 12) {
                VStack(spacing: 12) {
                    playerArea
                    ShortsTransportBar(controller: controller)
                }
                sidePanel
                    .frame(width: 360)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .background(Theme.background)
        .task {
            controller.prepare()
            controller.refreshReasoningOptions()
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

            VStack(alignment: .leading, spacing: 1) {
                Text("Нарезка на shorts")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text("\(controller.fileName) · \(TimeFormat.compact(controller.sourceDuration))")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Label("Только русская речь", systemImage: "character.bubble")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.leading, 84)  // место под «светофор» окна
        .padding(.trailing, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Плеер

    private var playerArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(Color.black)
            Button {
                controller.togglePlay()
            } label: {
                PlayerLayerView(player: controller.player)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(controller.isPlaying ? "Поставить просмотр на паузу" : "Воспроизвести просмотр")
            .accessibilityIdentifier("shorts.player")
            if let error = controller.prepareError {
                VStack(spacing: 10) {
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
                VStack(spacing: 10) {
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.system(size: 32, weight: .light))
                    Text("Выбери параметры справа\nи нажми «Найти моменты»")
                        .multilineTextAlignment(.center)
                        .font(.system(size: 14, design: .rounded))
                }
                .foregroundStyle(.white.opacity(0.55))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Боковая панель

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader
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
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            if !controller.candidates.isEmpty {
                exportBar
            }
        }
        .cardStyle()
    }

    private var panelHeader: some View {
        HStack {
            Label("Короткие ролики", systemImage: "sparkles.rectangle.stack")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Button {
                controller.cancelAnalysis()
                app.closeShorts()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.textSecondary.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }

    // MARK: - Настройки и запуск

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
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

            Picker("Модель", selection: $controller.model) {
                ForEach(SmartEditModel.allCases, id: \.self) { model in
                    Text(model.title).tag(model)
                }
            }

            Picker("Размышления", selection: $controller.reasoningChoice) {
                ForEach(controller.reasoningOptions) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            if controller.reasoningOptions.count > 1 {
                Text("Глубина «размышлений» модели. Выше уровень — вдумчивее отбор, но дольше и дороже анализ.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            keyControls

            Label(
                "В OpenRouter уходит текст расшифровки — он может содержать произнесённые личные данные. Звук, видео и пути файлов остаются на Mac.",
                systemImage: "lock.shield.fill"
            )
            .font(.system(size: 10.5))
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.background)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))

            if !SmartEditPlatform.isSupported {
                Label("Нарезка доступна на Mac с Apple Silicon.", systemImage: "cpu")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.danger)
            }

            if let error = controller.prepareError {
                errorLabel(error)
            } else if case .failed(let message) = controller.status {
                errorLabel(message)
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
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .disabled(analyzeDisabled)
            .accessibilityIdentifier("shorts.analyze")

            Link("Получить ключ OpenRouter", destination: URL(string: "https://openrouter.ai/settings/keys")!)
                .font(.system(size: 10.5, weight: .medium))
        }
    }

    private var analyzeButtonTitle: String {
        if case .failed = controller.status { return "Повторить анализ" }
        if controller.status == .ready { return "Искать ещё раз" }
        return "Найти моменты"
    }

    private var analyzeDisabled: Bool {
        controller.openRouterKeyStatus != .saved || controller.prepareError != nil
            || controller.sourceDuration < ShortsLimits.minSourceDuration || !SmartEditPlatform.isSupported
    }

    private func errorLabel(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11))
            .foregroundStyle(Theme.danger)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.danger.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
    }

    // MARK: - Ключ OpenRouter

    @ViewBuilder
    private var keyControls: some View {
        switch controller.openRouterKeyStatus {
        case .saved where !replacingKey:
            HStack(spacing: 10) {
                Label("Ключ сохранён", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
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
                        .font(.system(size: 10.5, weight: .medium))
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
                if case .checking = controller.openRouterKeyStatus {
                    Label("Проверяю ключ…", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                } else if case .failed(let message) = controller.openRouterKeyStatus {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundStyle(Theme.danger)
                }
            }
        }
    }

    private var isCheckingKey: Bool {
        if case .checking = controller.openRouterKeyStatus { return true }
        return false
    }

    // MARK: - Прогресс анализа

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(value: progressValue)
                .progressViewStyle(.linear)
                .tint(Theme.accent)
            Text(statusTitle)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Отменить анализ") { controller.cancelAnalysis() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(12)
        .background(Theme.accent.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
            HStack {
                Text(
                    "\(controller.candidates.count) \(Plurals.candidates(controller.candidates.count)) · выбрано \(controller.selectedCount)"
                )
                .font(.system(size: 11, weight: .semibold))
                Spacer()
                Button("Искать заново") { controller.analyze() }
                    .buttonStyle(.link)
                    .font(.system(size: 10))
                    .disabled(controller.openRouterKeyStatus != .saved)
            }
            ForEach(controller.candidates) { candidate in
                candidateCard(candidate)
            }
        }
    }

    private func candidateCard(_ candidate: ShortCandidate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(
                isOn: Binding(
                    get: { controller.candidates.first(where: { $0.id == candidate.id })?.enabled ?? false },
                    set: { _ in controller.toggleCandidate(candidate.id) }
                )
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(candidate.rank). \(candidate.title)")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(2)
                    if !candidate.hook.isEmpty {
                        Text("«\(candidate.hook)…»")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .italic()
                            .foregroundStyle(Theme.accent)
                            .lineLimit(1)
                    }
                    Text(candidate.excerpt)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(3)
                }
            }
            Text(candidate.reason)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(3)
            Text(
                "Хук \(candidate.hookScore) · Отдельно \(candidate.standaloneScore) · Польза \(candidate.payoffScore) · Темп \(candidate.pacingScore)"
            )
            .font(.system(size: 9.5, design: .monospaced))
            .foregroundStyle(Theme.textSecondary.opacity(0.85))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            HStack {
                Text(TimeFormat.compact(candidate.duration))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.background)
                    .clipShape(Capsule())
                if !candidate.pattern.isEmpty {
                    Text(candidate.pattern)
                        .font(.system(size: 10, weight: .medium))
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
                        .font(.system(size: 10.5, weight: .medium))
                }
                .buttonStyle(.link)
            }
        }
        .padding(9)
        .background(Theme.clipBackground.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall))
    }

    // MARK: - Экспорт

    private var exportBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch controller.exportState {
            case .idle:
                exportControls
            case .failed(let message):
                errorLabel(message)
                exportControls
            case .exporting(let done, let total, let progress):
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: (Double(done) + progress) / Double(max(1, total)))
                        .progressViewStyle(.linear)
                        .tint(Theme.accent)
                    HStack {
                        Text("Сохраняю ролик \(min(done + 1, total)) из \(total)…")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Button("Отменить") { controller.cancelExport() }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
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
                            .font(.system(size: 11))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Theme.card)
    }

    private var exportControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $controller.cropVertical) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Вертикальный кадр 9:16")
                        .font(.system(size: 12, weight: .medium))
                    Text("Вырез по центру кадра — для Reels и Shorts")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .toggleStyle(.switch)

            HStack(spacing: 10) {
                Picker("Качество", selection: $controller.quality) {
                    ForEach(ExportQuality.allCases) { quality in
                        Text(quality.title).tag(quality)
                    }
                }
                .frame(maxWidth: 160)

                Spacer()

                Button {
                    controller.chooseFolderAndExport()
                } label: {
                    Label(
                        "Сохранить (\(controller.selectedCount))",
                        systemImage: "square.and.arrow.down"
                    )
                    .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(controller.selectedCount == 0)
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
        HStack(spacing: 14) {
            Text(TimeFormat.short(controller.currentTime))
                .font(.system(size: 14, weight: .medium, design: .monospaced))
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

            Text("Просмотр — кнопка у карточки")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 150, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .cardStyle()
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
