import SwiftUI

/// Окно сохранения готового видео.
struct ExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: EditorController
    @StateObject private var export = ExportModel()
    @State private var quality: ExportQuality = .high
    @State private var audioWarning: String?
    @State private var sourceSize: CGSize?

    var body: some View {
        VStack(spacing: 20) {
            switch export.state {
            case .idle:
                chooser
            case .exporting:
                progressView
            case .done(let url):
                doneView(url)
            case .failed(let message):
                failedView(message)
            }
        }
        .padding(28)
        .frame(width: 440)
        .background(Theme.background)
        .task { sourceSize = await controller.sourceDisplaySize() }
    }

    // MARK: - Выбор качества

    private var chooser: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text("Сохранить видео")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text("Итог: \(TimeFormat.spoken(controller.duration)) · формат MP4")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }

            VStack(spacing: 8) {
                ForEach(ExportQuality.allCases) { q in
                    QualityRow(quality: q,
                               estimate: q.estimateText(
                                   duration: controller.duration,
                                   displaySize: sourceSize ?? CGSize(width: 1920, height: 1080)),
                               selected: quality == q) { quality = q }
                }
            }

            HStack(spacing: 12) {
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
            }
        }
    }

    private func startExport() {
        guard let url = export.chooseDestination(projectName: controller.project.name) else { return }
        Task {
            let (composition, audioMix, warning) = await controller.compositionForExport()
            audioWarning = warning
            export.export(composition: composition, audioMix: audioMix, quality: quality, to: url)
        }
    }

    private var audioWarningLine: some View {
        Group {
            if let audioWarning {
                Label(audioWarning, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - Состояния

    private var progressView: some View {
        VStack(spacing: 16) {
            Text("Сохраняю видео…")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
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
        }
    }

    private func doneView(_ url: URL) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("Готово!")
                .font(.system(size: 20, weight: .bold, design: .rounded))
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
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Закрыть") { dismiss() }
                    .buttonStyle(.bordered)
                Button("Попробовать ещё раз") { export.state = .idle }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
        }
    }
}

private struct QualityRow: View {
    let quality: ExportQuality
    let estimate: String
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(selected ? Theme.accent : Theme.textSecondary.opacity(0.5))
                VStack(alignment: .leading, spacing: 2) {
                    Text(quality.title)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    Text(quality.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Text(estimate)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
            }
            .padding(12)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                    .stroke(selected ? Theme.accent : Color.black.opacity(0.06), lineWidth: selected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}
