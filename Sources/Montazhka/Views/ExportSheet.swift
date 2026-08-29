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
            case .done(let url):
                doneView(url)
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
                    .font(.system(size: Theme.TypeScale.screenTitle, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Итог: \(TimeFormat.spoken(controller.duration)) · формат MP4")
                    .font(.system(size: Theme.TypeScale.body))
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

    private var audioWarningLine: some View {
        Group {
            if let audioWarning = export.audioWarning {
                Label(audioWarning, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - Состояния

    private var preparingView: some View {
        VStack(spacing: 16) {
            Text("Подготавливаю видео…")
                .font(.system(size: Theme.TypeScale.sectionTitle, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            ProgressView()
                .controlSize(.large)
                .tint(Theme.accent)
            Text("Собираю дорожки и обрабатываю звук")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
            Button("Отменить") { export.cancel() }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("export.cancelPreparation")
        }
    }

    private var progressView: some View {
        VStack(spacing: 16) {
            Text("Сохраняю видео…")
                .font(.system(size: Theme.TypeScale.sectionTitle, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            ProgressView(value: export.progress)
                .progressViewStyle(.linear)
                .tint(Theme.accent)
            Text("\(Int(export.progress * 100))%")
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
            audioWarningLine
            Button("Отменить") { export.cancel() }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("export.cancel")
        }
    }

    private func doneView(_ url: URL) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("Готово!")
                .font(.system(size: Theme.TypeScale.screenTitle, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            Text(url.lastPathComponent)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
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

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(Theme.pauseHighlight)
            Text("Что-то пошло не так")
                .font(.system(size: Theme.TypeScale.screenTitle, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
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

private struct QualityRow: View {
    let quality: ExportQuality
    let displaySize: CGSize
    let estimate: String
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(selected ? Theme.accent : Theme.textSecondary.opacity(0.5))
                VStack(alignment: .leading, spacing: Theme.Spacing.compact) {
                    Text(quality.title)
                        .font(.system(size: Theme.TypeScale.body, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("\(dimensionsText) · \(purposeText)")
                        .font(.system(size: Theme.TypeScale.helper))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Text(estimate)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, Theme.Spacing.small)
            .background(selected ? Theme.selected : Color.clear)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("export.quality.\(quality.rawValue)")
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
