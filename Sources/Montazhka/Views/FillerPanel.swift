import SwiftUI

/// Локальный поиск слов-паразитов с обязательным подтверждением перед вырезкой.
struct FillerPanel: View {
    @ObservedObject var controller: EditorController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Слова-паразиты")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button {
                    controller.cancelFillerDetection()
                    withAnimation { controller.showFillerPanel = false }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.textSecondary.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Речь распознаётся локально на этом Mac. Проверь найденные места и оставь галочки только там, где слово действительно лишнее.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)

                    detectButton
                    statusBlock

                    if !controller.fillerCandidates.isEmpty {
                        resultsBlock
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }

            if !controller.fillerCandidates.isEmpty { cutBar }
        }
        .cardStyle()
    }

    private var detectButton: some View {
        Button {
            controller.detectFillers()
        } label: {
            Label("Найти слова-паразиты", systemImage: "text.magnifyingglass")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.accent)
        .disabled(isWorking || controller.project.clips.isEmpty)
    }

    private var isWorking: Bool {
        if case .transcribing = controller.fillerStatus { return true }
        return false
    }

    @ViewBuilder
    private var statusBlock: some View {
        switch controller.fillerStatus {
        case .idle:
            if controller.fillerCandidates.isEmpty {
                Text("Ищем: э, эм, ну, типа, как бы")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }
        case .transcribing(let done, let total):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Распознаю речь… \(done) из \(total)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Отменить") { controller.cancelFillerDetection() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.accent)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
        }
    }

    private var resultsBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            let enabled = controller.fillerCandidates.filter(\.enabled)
            HStack {
                Text("Найдено: \(controller.fillerCandidates.count)")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Spacer()
                Button(enabled.count == controller.fillerCandidates.count ? "Снять все" : "Выбрать все") {
                    controller.setAllFillerCandidates(enabled: enabled.count != controller.fillerCandidates.count)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.accent)
            }

            ForEach(controller.fillerCandidates) { candidate in
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { candidate.enabled },
                        set: { _ in controller.toggleFillerCandidate(candidate.id) }
                    ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()

                    VStack(alignment: .leading, spacing: 2) {
                        Text("«\(candidate.text)»")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                        Text(TimeFormat.compact(candidate.start))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Button {
                        controller.previewFillerCandidate(candidate)
                    } label: {
                        Image(systemName: "play.circle")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                        .fill(candidate.enabled ? Color.orange.opacity(0.09) : Color.black.opacity(0.02))
                )
            }
        }
    }

    private var cutBar: some View {
        VStack(spacing: 8) {
            Divider()
            let count = controller.fillerCandidates.filter(\.enabled).count
            Button {
                controller.cutEnabledFillers()
            } label: {
                Label("Вырезать выбранные (\(count))", systemImage: "scissors")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(count == 0)

            Button("Убрать подсветку") { controller.fillerCandidates = [] }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }
}
