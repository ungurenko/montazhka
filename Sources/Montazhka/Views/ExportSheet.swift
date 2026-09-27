import SwiftUI

/// Окно сохранения готового видео.
struct ExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    var controller: EditorController
    @State private var export = ExportModel()
    @State private var quality: ExportQuality = .high
    @State private var sourceSize: CGSize?

    var body: some View {
        VStack(spacing: Theme.Spacing.large) {
            switch export.state {
            case .idle:
                chooser
            case .preparing:
                preparingView
            case .exporting:
                progressView
            case .done(let url, let report):
                doneView(url, result: ExportResultText(report: report))
            case .failed(let message):
                failedView(message)
            }
        }
        .padding(Theme.Spacing.large)
        .frame(width: 480)
        .background(Theme.background)
        .task { sourceSize = await controller.sourceDisplaySize() }
        .onDisappear { export.cancel() }
    }

    // MARK: - Выбор качества

    private var chooser: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Сохранить видео")
                    .typeStyle(.screenTitle)
                    .foregroundStyle(Theme.textPrimary)
                Text("Итог: \(TimeFormat.spoken(controller.duration)) · формат MP4")
                    .typeStyle(.body)
                    .foregroundStyle(Theme.textSecondary)
            }

            VStack(spacing: 0) {
                ForEach(ExportQuality.allCases) { q in
                    QualityRow(
                        quality: q,
                        displaySize: sourceSize ?? CGSize(width: 1920, height: 1080),
                        estimate: q.estimateText(
                            duration: controller.duration,
                            displaySize: sourceSize ?? CGSize(width: 1920, height: 1080)),
                        selected: quality == q
                    ) { quality = q }
                    if q != ExportQuality.allCases.last { Divider().padding(.leading, 44) }
                }
            }
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .stroke(Theme.border, lineWidth: 1)
            }

            options

            HStack(spacing: 12) {
                Spacer()
                Button("Отмена") { dismiss() }
                    .buttonStyle(.bordered)
                Button {
                    startExport()
                } label: {
                    Label("Сохранить", systemImage: "square.and.arrow.down")
                        .fontWeight(.semibold)
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .accessibilityIdentifier("export.start")
            }
        }
    }

    private func startExport() {
        guard let url = export.chooseDestination(projectName: controller.project.name) else { return }
        export.start(preparer: controller, quality: quality, to: url)
    }

    // MARK: - Звук и субтитры

    private var options: some View {
        VStack(alignment: .leading, spacing: 0) {
            ExportOptionRow(
                title: "Выровнять громкость под YouTube и соцсети",
                hints: ["−14 LUFS, как требуют площадки"],
                isOn: preference(\.normalizeLoudness),
                accessibilityIdentifier: "export.normalizeLoudness")
            // У черновика шортса свои субтитры: эта галочка на него не действует.
            if controller.project.shorts == nil {
                Divider().padding(.leading, Theme.Spacing.snug)
                ExportOptionRow(
                    title: "Вшить субтитры в видео",
                    hints: subtitleHints,
                    isOn: preference(\.burnSubtitles),
                    accessibilityIdentifier: "export.burnSubtitles")
            }
        }
        .cardStyle()
    }

    /// Галочка доступна всегда: без готовой расшифровки речь распознаётся при сохранении.
    private var subtitleHints: [String] {
        let file = "Файл субтитров для YouTube сохранится рядом с видео"
        let recognized = !controller.previewSubtitleCues.isEmpty
        return recognized ? [file] : ["Речь распознается при экспорте, если модель скачана", file]
    }

    /// Галочка пишет в проект через контроллер — так её можно отменить ⌘Z.
    private func preference(_ keyPath: WritableKeyPath<ExportPreferences, Bool>) -> Binding<Bool> {
        Binding(
            get: { controller.project.export[keyPath: keyPath] },
            set: { value in
                var preferences = controller.project.export
                preferences[keyPath: keyPath] = value
                controller.setExportPreferences(preferences)
            })
    }

    private var audioWarningLine: some View {
        Group {
            if let audioWarning = export.audioWarning {
                Label(audioWarning, systemImage: "exclamationmark.triangle.fill")
                    .typeStyle(.helper)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - Состояния

    private var preparingView: some View {
        VStack(spacing: 16) {
            Text("Подготавливаю видео…")
                .typeStyle(.sectionTitle)
                .foregroundStyle(Theme.textPrimary)
            ProgressView()
                .controlSize(.large)
                .tint(Theme.accent)
            Text(export.stageCaption ?? ExportPreparationStep.assembling.activitySnapshot.caption)
                .typeStyle(.body)
                .foregroundStyle(Theme.textSecondary)
                .accessibilityIdentifier("export.stage")
            Button("Отменить") { export.cancel() }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("export.cancelPreparation")
        }
    }

    private var progressView: some View {
        VStack(spacing: 16) {
            Text("Сохраняю видео…")
                .typeStyle(.sectionTitle)
                .foregroundStyle(Theme.textPrimary)
            ProgressView(value: export.progress)
                .progressViewStyle(.linear)
                .tint(Theme.accent)
            HStack(spacing: Theme.Spacing.small) {
                Text(export.stageCaption ?? "")
                    .typeStyle(.body)
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("export.stage")
                Spacer()
                Text("\(Int(export.progress * 100))%")
                    .typeStyle(.time)
                    .foregroundStyle(Theme.textSecondary)
            }
            audioWarningLine
            Button("Отменить") { export.cancel() }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("export.cancel")
        }
    }

    private func doneView(_ url: URL, result: ExportResultText) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: IconScale.hero))
                .foregroundStyle(.green)
            Text("Готово!")
                .typeStyle(.screenTitle)
                .foregroundStyle(Theme.textPrimary)
            Text(url.lastPathComponent)
                .typeStyle(.body)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            resultSummary(result)
            ForEach(Array(result.notices.enumerated()), id: \.offset) { _, notice in
                StatusBanner(kind: .warning, title: notice.title, hint: notice.hint)
            }
            audioWarningLine
            HStack(spacing: 12) {
                Button("Показать в Finder") { export.revealInFinder(url) }
                    .buttonStyle(.bordered)
                Button("Закрыть") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
        }
    }

    /// Громкость готового файла и его субтитры — по строке на каждое.
    @ViewBuilder
    private func resultSummary(_ result: ExportResultText) -> some View {
        if result.loudness != nil || result.subtitles != nil || result.subtitlesSkipped != nil {
            VStack(alignment: .leading, spacing: Theme.Spacing.snug) {
                if let loudness = result.loudness {
                    ExportResultRow(systemImage: "speaker.wave.2", title: loudness, hint: result.loudnessHint)
                        .help(
                            "LUFS — общая громкость ролика, dBTP — самый громкий момент. "
                                + "Площадки ждут около −14 LUFS и пик не выше −1 dBTP"
                        )
                        .accessibilityIdentifier("export.result.loudness")
                }
                if let subtitles = result.subtitles, let subtitlesURL = result.subtitlesURL {
                    ExportResultRow(
                        systemImage: "captions.bubble", title: subtitles,
                        action: StatusBanner.Action(
                            title: "Показать", accessibilityIdentifier: "export.result.revealSubtitles"
                        ) { export.revealInFinder(subtitlesURL) })
                } else if let skipped = result.subtitlesSkipped {
                    ExportResultRow(systemImage: "captions.bubble", title: skipped, isSecondary: true)
                }
            }
            .padding(Theme.Spacing.snug)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
        }
    }

    private func failedView(_ error: UserFacingError) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: IconScale.hero - 4))
                .foregroundStyle(Theme.warning)
            Text(error.what)
                .typeStyle(.screenTitle)
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
            if let hint = error.hint {
                Text(hint)
                    .typeStyle(.body)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 12) {
                Button("Закрыть") { dismiss() }
                    .buttonStyle(.bordered)
                Button("Попробовать ещё раз") { export.retry() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
        }
    }
}

/// Галочка окна экспорта: что делает и что для неё нужно.
private struct ExportOptionRow: View {
    let title: String
    let hints: [String]
    @Binding var isOn: Bool
    let accessibilityIdentifier: String

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.snug) {
            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                Text(title)
                    .typeStyle(.bodyEmphasis)
                    .foregroundStyle(Theme.textPrimary)
                ForEach(hints, id: \.self) { hint in
                    Text(hint)
                        .typeStyle(.helper)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Theme.Spacing.small)
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(Theme.accent)
                .accessibilityHint(hints.joined(separator: ". "))
                .accessibilityIdentifier(accessibilityIdentifier)
        }
        .padding(Theme.Spacing.snug)
    }
}

/// Строка итога: значок, текст и, если есть, действие справа.
private struct ExportResultRow: View {
    let systemImage: String
    let title: String
    var hint: String?
    var isSecondary = false
    var action: StatusBanner.Action?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            Image(systemName: systemImage)
                .font(.system(size: IconScale.inline))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: Theme.Spacing.medium)
            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                Text(title)
                    .typeStyle(.body)
                    .foregroundStyle(isSecondary ? Theme.textSecondary : Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let hint {
                    Text(hint)
                        .typeStyle(.helper)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: Theme.Spacing.small)
            if let action {
                Button(action.title, action: action.perform)
                    .buttonStyle(.mzQuiet(compact: true))
                    .accessibilityIdentifier(action.accessibilityIdentifier ?? "")
            }
        }
    }
}

private struct QualityRow: View {
    let quality: ExportQuality
    let displaySize: CGSize
    let estimate: String
    let selected: Bool
    let select: () -> Void

    var body: some View {
        SelectableRow(
            marker: .choice,
            title: quality.title,
            subtitle: "\(dimensionsText) · \(purposeText)",
            isSelected: selected,
            accessibilityIdentifier: "export.quality.\(quality.rawValue)",
            select: select
        ) {
            Text(estimate)
                .typeStyle(.helper)
                .monospaced()
                .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
        }
    }

    private var dimensionsText: String {
        let size = quality.targetDimensions(forDisplaySize: displaySize)
        return "\(Int(size.width)) × \(Int(size.height))"
    }

    private var purposeText: String {
        switch quality {
        case .maximum: return "исходное качество"
        case .high: return "лучшая картинка"
        case .medium: return "баланс качества и размера"
        case .compact: return "для быстрой отправки"
        }
    }
}

// MARK: - Итог простыми словами

/// Итог готового файла простыми словами: громкость, субтитры, замечания.
/// Чистая функция отчёта — без окна и файлов.
struct ExportResultText: Equatable {
    /// Замечание: файл сохранён, но что-то вышло не так, как задумано.
    struct Notice: Equatable {
        let title: String
        var hint: String?
    }

    /// «Громкость: −14,0 LUFS · пик −1,3 dBTP»; nil — громкость не замерена.
    let loudness: String?
    /// Что значат числа громкости; nil — их объясняет замечание.
    let loudnessHint: String?
    /// «Субтитры: Ролик.srt»; nil — файла субтитров нет.
    let subtitles: String?
    let subtitlesURL: URL?
    /// Почему субтитров нет.
    let subtitlesSkipped: String?
    let notices: [Notice]

    /// Начало замечания `FinalExport` о промахе мимо стандарта. Его числа уже
    /// в строке громкости, поэтому вместо него — объяснение простыми словами.
    private static let missedTargetPrefix = "Громкость не вышла на стандарт"

    init(report: FinalExportReport) {
        loudness = report.loudness.flatMap { measurement in
            measurement.integratedLUFS.map { integrated in
                "Громкость: \(Self.decibels(integrated)) LUFS · пик \(Self.decibels(measurement.truePeakDBTP)) dBTP"
            }
        }
        let missedTarget = report.targetMet == false
        if loudness == nil || missedTarget {
            loudnessHint = nil
        } else {
            loudnessHint = report.normalized ? "Как требуют YouTube и соцсети" : "Громкость оставлена как есть"
        }
        subtitlesURL = report.subtitlesURL
        subtitles = report.subtitlesURL.map { "Субтитры: \($0.lastPathComponent)" }
        subtitlesSkipped = report.subtitlesURL == nil ? report.subtitlesSkippedReason : nil

        var notices: [Notice] = []
        if missedTarget {
            notices.append(
                Notice(
                    title: "Громкость не совсем по стандарту площадок",
                    hint: "Ролик может звучать чуть тише или громче других. Выкладывать можно"))
        }
        notices += report.warnings
            .filter { !(missedTarget && $0.hasPrefix(Self.missedTargetPrefix)) }
            .map { Notice(title: $0) }
        self.notices = notices
    }

    /// Десятые доли через запятую и настоящий минус: «−14,0». Ноль без знака.
    static func decibels(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        let tenths = Int((value * 10).rounded())
        let sign = tenths < 0 ? "−" : ""
        return "\(sign)\(abs(tenths) / 10),\(abs(tenths) % 10)"
    }
}
