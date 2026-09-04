import SwiftUI

struct SmartEditPanel: View {
    @Bindable var controller: EditorController
    @State private var keyInput = ""
    @State private var replacingKey = false

    private enum ProcessStage: Int, CaseIterable {
        case connection = 1
        case model
        case transcription
        case editing

        var title: String {
            switch self {
            case .connection: return "Подключение"
            case .model: return "Локальная модель"
            case .transcription: return "Расшифровка"
            case .editing: return "Анализ и склейки"
            }
        }

        var idleSubtitle: String {
            switch self {
            case .connection: return "Агент и модель для анализа текста"
            case .model: return "Подготовка распознавания речи"
            case .transcription: return "Текст с точными таймкодами"
            case .editing: return "Оговорки, дубли и безопасные стыки"
            }
        }
    }

    var body: some View {
        InspectorPanel(
            title: "Умный монтаж",
            systemImage: "wand.and.sparkles",
            accessibilityIdentifier: "editor.inspector.smartEdit",
            close: {
                controller.cancelSmartEdit()
                withAnimation { controller.activeInspector = nil }
            }
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                    process
                    results
                }
                .padding(.horizontal, Theme.Spacing.medium)
                .padding(.bottom, Theme.Spacing.medium)
            }
        } footer: {
            if !controller.smartEditCandidates.isEmpty { applyBar }
        }
        .task {
            controller.aiConnection.refreshAgents()
            controller.aiConnection.refreshReasoningOptions()
        }
    }

    private var process: some View {
        VStack(alignment: .leading, spacing: 0) {
            stage(.connection) {
                if shouldExpandConnection { connectionContent }
            }
            stage(.model) {
                if activeStage == .model { activeStageContent }
            }
            stage(.transcription) {
                if activeStage == .transcription { activeStageContent }
            }
            stage(.editing, isLast: true) {
                if activeStage == .editing { activeStageContent }
            }
        }
    }

    private func stage<Content: View>(
        _ stage: ProcessStage,
        isLast: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                stageMarker(stage)
                if !isLast {
                    Rectangle()
                        .fill(connectorColor(after: stage))
                        .frame(width: 2)
                        .frame(minHeight: stage == .connection && shouldExpandConnection ? 180 : 34)
                }
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                VStack(alignment: .leading, spacing: Theme.Spacing.compact) {
                    Text(stage.title)
                        .typeStyle(.bodyEmphasis)
                        .foregroundStyle(stageTitleColor(stage))
                    Text(stageSubtitle(stage))
                        .typeStyle(.helper)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, isLast ? 0 : 16)
        }
    }

    @ViewBuilder
    private func stageMarker(_ stage: ProcessStage) -> some View {
        if isStageComplete(stage) {
            Image(systemName: "checkmark")
                .font(.system(size: Theme.TypeScale.helper, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.green)
                .clipShape(Circle())
        } else if activeStage == stage && isWorking {
            ProgressView()
                .controlSize(.small)
                .frame(width: 22, height: 22)
        } else {
            Text("\(stage.rawValue)")
                .typeStyle(.helperEmphasis)
                .foregroundStyle(activeStage == stage ? .white : Theme.textSecondary)
                .frame(width: 22, height: 22)
                .background(activeStage == stage ? Theme.accent : Theme.background)
                .clipShape(Circle())
        }
    }

    private var connectionContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            AIProviderControls(
                connection: controller.aiConnection)

            AIReasoningPicker(connection: controller.aiConnection)
                .labelsHidden()
                .frame(maxWidth: .infinity)
            if controller.aiConnection.reasoningOptions.count > 1 {
                Text("Глубина «размышлений» модели. Выше уровень — вдумчивее склейки, но дольше анализ.")
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
                Label("Умный монтаж доступен на Mac с Apple Silicon.", systemImage: "cpu")
                    .typeStyle(.helperEmphasis)
                    .foregroundStyle(Theme.danger)
            }

            if controller.aiConnection.provider == .openRouter {
                Link("Получить ключ OpenRouter", destination: URL(string: "https://openrouter.ai/settings/keys")!)
                    .typeStyle(.helperEmphasis)
            }
        }
    }

    @ViewBuilder
    private var activeStageContent: some View {
        if isWorking, let activity = controller.activity.activity(.smartEdit) {
            ActivityBlock(activity: activity) { controller.cancelSmartEdit() }
        } else if activeStage == .editing && controller.smartEditStatus.allowsAnalysisStart {
            Button {
                controller.analyzeSmartEdits()
            } label: {
                Label(analysisButtonTitle, systemImage: "sparkles")
                    .typeStyle(.bodyEmphasis)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .disabled(
                !controller.aiConnection.isReady || controller.project.clips.isEmpty
                    || !SmartEditPlatform.isSupported)
        }
    }

    private var analysisButtonTitle: String {
        if case .failed = controller.smartEditStatus { return "Повторить анализ" }
        return "Проанализировать речь"
    }

    private var shouldExpandConnection: Bool {
        !isWorking && controller.smartEditCandidates.isEmpty && controller.smartEditStatus != .ready
    }

    private var activeStage: ProcessStage {
        switch controller.smartEditStatus {
        case .preparingModel: return .model
        case .transcribing: return .transcription
        case .proposing, .reviewing, .preparingCuts, .ready: return .editing
        case .idle, .failed: return controller.aiConnection.isReady ? .editing : .connection
        }
    }

    private func isStageComplete(_ stage: ProcessStage) -> Bool {
        switch stage {
        case .connection:
            return controller.aiConnection.isReady && activeStage != .connection
        case .model:
            switch controller.smartEditStatus {
            case .transcribing, .proposing, .reviewing, .preparingCuts, .ready: return true
            default: return false
            }
        case .transcription:
            switch controller.smartEditStatus {
            case .proposing, .reviewing, .preparingCuts, .ready: return true
            default: return false
            }
        case .editing:
            return controller.smartEditStatus == .ready
        }
    }

    private func connectorColor(after stage: ProcessStage) -> Color {
        isStageComplete(stage) ? Color.green.opacity(0.35) : Theme.textSecondary.opacity(0.18)
    }

    private func stageTitleColor(_ stage: ProcessStage) -> Color {
        activeStage == stage || isStageComplete(stage) ? Theme.textPrimary : Theme.textSecondary
    }

    private func stageSubtitle(_ stage: ProcessStage) -> String {
        if stage == .connection && !shouldExpandConnection && controller.aiConnection.isReady {
            return controller.aiConnection.selectionTitle
        }
        return stage.idleSubtitle
    }

    private var isWorking: Bool {
        switch controller.smartEditStatus {
        case .preparingModel, .transcribing, .proposing, .reviewing, .preparingCuts: return true
        default: return false
        }
    }

    /// Во что обошёлся последний запуск. Молчит, когда запросов не было.
    @ViewBuilder
    private var usageLine: some View {
        if let usage = controller.smartEditUsage.summary {
            Text("Расход: \(usage)")
                .typeStyle(.helper)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    @ViewBuilder
    private var results: some View {
        if case .failed(let error) = controller.smartEditStatus {
            VStack(alignment: .leading, spacing: 8) {
                StatusBanner(
                    error: error,
                    actions: [
                        StatusBanner.Action(
                            title: "Повторить анализ",
                            perform: { controller.analyzeSmartEdits() })
                    ])
                usageLine
            }
        } else if controller.smartEditStatus == .ready && controller.smartEditCandidates.isEmpty {
            StatusBanner(
                kind: .success,
                title: "Речь уже звучит чисто",
                hint: "Надёжных вырезок не нашлось — резать нечего.")
        } else if !controller.smartEditCandidates.isEmpty {
            let obvious = controller.smartEditCandidates.filter { $0.kind != .semanticRepeat }
            let semantic = controller.smartEditCandidates.filter { $0.kind == .semanticRepeat }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(
                        "\(controller.smartEditCandidates.count) предложений · экономия \(TimeFormat.spoken(selectedDuration))"
                    )
                    .typeStyle(.helperEmphasis)
                    Spacer()
                    if !obvious.isEmpty {
                        Button(obvious.allSatisfy(\.enabled) ? "Снять явные" : "Выбрать явные") {
                            controller.setAllObviousSmartEdits(enabled: !obvious.allSatisfy(\.enabled))
                        }
                        .buttonStyle(.link)
                        .typeStyle(.helper)
                    }
                }
                usageLine
                if !obvious.isEmpty { candidateGroup("Явные исправления", candidates: obvious) }
                if !semantic.isEmpty { candidateGroup("Смысловые повторы", candidates: semantic) }
            }
        }
    }

    private func candidateGroup(_ title: String, candidates: [SmartEditCandidate]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).typeStyle(.helperEmphasis)
            ForEach(candidates) { candidate in candidateRow(candidate) }
        }
    }

    private func candidateRow(_ candidate: SmartEditCandidate) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Toggle(
                isOn: Binding(
                    get: { controller.smartEditCandidates.first(where: { $0.id == candidate.id })?.enabled ?? false },
                    set: { _ in controller.toggleSmartEditCandidate(candidate.id) }
                )
            ) {
                VStack(alignment: .leading, spacing: Theme.Spacing.compact) {
                    Text(candidate.originalText)
                        .typeStyle(.helperEmphasis)
                        .lineLimit(3)
                    Text("\(candidate.kind.title) · \(String(format: "%.1f", candidate.duration)) сек")
                        .typeStyle(.helper)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Text(candidate.reason)
                .typeStyle(.helper)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Оригинал") { controller.previewSmartEditOriginal(candidate) }
                Button("Склейка") { controller.previewSmartEditJoin(candidate) }
            }
            .buttonStyle(.link)
            .typeStyle(.helperEmphasis)
        }
        .padding(9)
        .background(Theme.clipBackground.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall))
    }

    private var selectedDuration: Double {
        controller.smartEditCandidates.filter(\.enabled).reduce(0) { $0 + $1.duration }
    }

    private var applyBar: some View {
        let count = controller.smartEditCandidates.filter(\.enabled).count
        return Button("Применить выбранное (\(count))") { controller.applySmartEdits() }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .disabled(count == 0)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.vertical, Theme.Spacing.small)
            .background(Theme.card)
    }
}
