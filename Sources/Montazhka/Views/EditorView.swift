@preconcurrency import AVFoundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Монтажный стол: плеер сверху, лента снизу, справа — панель поиска пауз.
struct EditorView: View {
    @Environment(AppModel.self) private var app
    var controller: EditorController
    @State private var projectName: String = ""
    @State private var showExport = false
    @State private var dropTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            topBar
            VSplitView {
                HStack(spacing: Theme.Spacing.medium) {
                    VStack(spacing: 0) {
                        playerArea
                        Divider()
                        TransportBar(controller: controller)
                    }
                    .cardStyle()

                    inspector
                }
                .frame(minHeight: 280)
                .padding(.horizontal, Theme.Spacing.medium)
                .padding(.bottom, Theme.Spacing.small)

                TimelineView(controller: controller)
                    .frame(minHeight: 180, idealHeight: 220, maxHeight: 360)
                    .padding(.horizontal, Theme.Spacing.medium)
                    .padding(.bottom, Theme.Spacing.medium)
            }
        }
        .background(Theme.background)
        .animation(
            reduceMotion ? .linear(duration: 0.12) : .easeInOut(duration: 0.2),
            value: controller.activeInspector
        )
        .sheet(isPresented: $showExport) {
            ExportSheet(controller: controller)
        }
        .alert("Файлы не найдены", isPresented: missingAlertBinding) {
            if let source = controller.missingSources.first {
                Button("Указать файл…") { chooseReplacement(for: source) }
            }
            Button("Позже", role: .cancel) {}
        } message: {
            Text(controller.missingFilesMessage ?? "")
        }
        .alert("Не удалось сохранить проект", isPresented: saveErrorBinding) {
            Button("Повторить") { Task { await controller.saveNow() } }
            Button("Закрыть", role: .cancel) { controller.dismissSaveError() }
        } message: {
            if case let .failed(message) = controller.saveStatus {
                Text(message)
            }
        }
        .onAppear {
            projectName = controller.project.name
        }
        .onDisappear {
            dropTask?.cancel()
            dropTask = nil
        }
        .focusedSceneValue(\.editorController, controller)
    }

    private func chooseReplacement(for source: MediaReference) {
        let panel = NSOpenPanel()
        panel.title = "Указать файл «\(source.displayName)»"
        panel.prompt = "Переподключить"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            if let message = await controller.relinkSource(id: source.id, to: url) {
                controller.missingFilesMessage = message
            }
        }
    }

    private var missingAlertBinding: Binding<Bool> {
        Binding(
            get: { controller.missingFilesMessage != nil },
            set: { if !$0 { controller.missingFilesMessage = nil } }
        )
    }

    private var saveErrorBinding: Binding<Bool> {
        Binding(
            get: {
                if case .failed = controller.saveStatus { return true }
                return false
            },
            set: { if !$0 { controller.dismissSaveError() } }
        )
    }

    // MARK: - Верхняя панель

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                app.closeProject()
            } label: {
                Label("Проекты", systemImage: "chevron.left")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .disabled(app.isProjectOperationInProgress)
            .accessibilityIdentifier("editor.back")

            TextField("Название", text: $projectName)
                .textFieldStyle(.plain)
                .font(.system(size: Theme.TypeScale.sectionTitle, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 220)
                .onSubmit { controller.renameProject(projectName) }
                .accessibilityIdentifier("editor.projectName")

            saveStatusView

            Spacer()

            Button {
                let urls = AppModel.pickVideos()
                controller.addClips(urls: urls)
            } label: {
                Label("Добавить видео", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("editor.addVideo")

            Menu {
                Button {
                    withAnimation {
                        controller.activeInspector = .pauses
                    }
                } label: {
                    Label(
                        "Найти паузы",
                        systemImage: controller.activeInspector == .pauses
                            ? "checkmark" : "waveform.badge.magnifyingglass")
                }
                Button {
                    withAnimation {
                        controller.activeInspector = .smartEdit
                    }
                } label: {
                    Label(
                        "Умный монтаж",
                        systemImage: controller.activeInspector == .smartEdit ? "checkmark" : "wand.and.sparkles")
                }
            } label: {
                Label("Чистка", systemImage: "wand.and.stars")
                    .foregroundStyle(
                        controller.activeInspector == .pauses || controller.activeInspector == .smartEdit
                            ? Theme.accent : Theme.textPrimary)
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .fixedSize()
            .accessibilityIdentifier("editor.cleanupMenu")

            Menu {
                Button {
                    withAnimation { controller.activeInspector = .voice }
                } label: {
                    Label(
                        "Улучшить голос",
                        systemImage: controller.activeInspector == .voice ? "checkmark" : "waveform.and.mic")
                }
                Button {
                    withAnimation { controller.activeInspector = .music }
                } label: {
                    Label(
                        "Фоновая музыка",
                        systemImage: controller.activeInspector == .music ? "checkmark" : "music.note")
                }
            } label: {
                Label("Звук", systemImage: "speaker.wave.2")
                    .foregroundStyle(
                        controller.activeInspector == .voice || controller.activeInspector == .music
                            ? Theme.accent : Theme.textPrimary)
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .fixedSize()
            .accessibilityIdentifier("editor.soundMenu")

            Button {
                controller.player.pause()
                showExport = true
            } label: {
                Label("Сохранить видео", systemImage: "square.and.arrow.up")
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .disabled(controller.project.clips.isEmpty)
            .accessibilityIdentifier("editor.export")
        }
        .padding(.leading, 84)  // место под «светофор» окна
        .padding(.trailing, 16)
        .frame(height: 56)
    }

    @ViewBuilder
    private var inspector: some View {
        switch controller.activeInspector {
        case .pauses:
            PausePanel(controller: controller)
                .frame(width: 340)
                .transition(inspectorTransition)
        case .smartEdit:
            SmartEditPanel(controller: controller)
                .frame(width: 340)
                .transition(inspectorTransition)
        case .voice:
            VoicePanel(controller: controller)
                .frame(width: 340)
                .transition(inspectorTransition)
        case .music:
            MusicPanel(controller: controller)
                .frame(width: 340)
                .transition(inspectorTransition)
        case nil:
            EmptyView()
        }
    }

    private var inspectorTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity)
    }

    @ViewBuilder
    private var saveStatusView: some View {
        switch controller.saveStatus {
        case .idle:
            EmptyView()
        case .saving:
            ProgressView()
                .controlSize(.small)
                .help("Сохраняю проект")
        case .saved:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.accent)
                .help("Проект сохранён")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help("Проект не сохранился")
        }
    }

    // MARK: - Плеер

    private var playerArea: some View {
        ZStack {
            Color.black
            if controller.project.clips.isEmpty {
                dropHint
            } else if controller.previewState == .ready {
                Button {
                    controller.togglePlay()
                } label: {
                    PlayerLayerView(player: controller.player)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(controller.isPlaying ? "Поставить видео на паузу" : "Воспроизвести видео")
                .accessibilityIdentifier("editor.player")
            }
            playerStatusOverlay
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
    }

    private var dropHint: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 36, weight: .light))
            Text("Перетащи сюда видео\nили нажми «Добавить видео»")
                .multilineTextAlignment(.center)
                .font(.system(size: Theme.TypeScale.sectionTitle))
        }
        .foregroundStyle(.white.opacity(0.55))
    }

    @ViewBuilder
    private var playerStatusOverlay: some View {
        switch controller.clipImportState {
        case .importing:
            playerProgress("Добавляю видео…")
        case .failed(let message) where controller.project.clips.isEmpty:
            playerError(title: "Видео не добавилось", message: message)
        default:
            switch controller.previewState {
            case .preparing:
                playerProgress("Подготавливаю проект…")
            case .failed(let message):
                playerError(title: "Не удалось подготовить проект", message: message)
            case .empty, .ready:
                if case .failed(let message) = controller.clipImportState {
                    VStack {
                        Spacer()
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.white)
                            .padding(Theme.Spacing.small)
                            .background(Color.orange.opacity(0.92))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .padding(12)
                    }
                }
            }
        }
    }

    private func playerProgress(_ text: String) -> some View {
        VStack(spacing: Theme.Spacing.small) {
            ProgressView()
                .controlSize(.regular)
                .tint(.white)
            Text(text)
                .font(.system(size: Theme.TypeScale.body, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.9))
    }

    private func playerError(title: String, message: String) -> some View {
        VStack(spacing: Theme.Spacing.small) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            Text(title)
                .font(.system(size: Theme.TypeScale.sectionTitle, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .lineLimit(4)
            if case .failed = controller.previewState {
                Button("Повторить") { controller.rebuildAndSeek(to: controller.currentTime) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .foregroundStyle(.white)
        .padding(24)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }
        dropTask?.cancel()
        dropTask = Task {
            let urls = await DroppedVideoLoader.load(from: fileProviders)
            guard !Task.isCancelled else { return }
            controller.addClips(urls: urls)
            dropTask = nil
        }
        return true
    }

}

// MARK: - Нижняя панель управления

private struct TransportBar: View {
    var controller: EditorController

    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            PlaybackTimeLabel(controller: controller)

            Spacer()

            ControlButton(icon: "backward.frame.fill", help: "Кадр назад (←)") {
                controller.stepFrames(-1)
            }
            PlayPauseControl(controller: controller)
                .disabled(controller.previewState != .ready)
            ControlButton(icon: "forward.frame.fill", help: "Кадр вперёд (→)") {
                controller.stepFrames(1)
            }

            Divider().frame(height: 22)

            ControlButton(icon: "scissors", help: "Разрезать в позиции ползунка (S)") {
                controller.splitAtPlayhead()
            }
            ControlButton(icon: "inset.filled.leadinghalf.rectangle", help: "Начало выделения (I)") {
                controller.markSelectionStart()
            }
            ControlButton(icon: "inset.filled.trailinghalf.rectangle", help: "Конец выделения (O)") {
                controller.markSelectionEnd()
            }
            ControlButton(icon: "selection.pin.in.out", help: "Прослушать выделение") {
                controller.previewSelection()
            }
            .disabled(controller.timelineSelection == nil)
            ControlButton(icon: "scissors.badge.ellipsis", help: "Вырезать выделение (X)") {
                controller.cutSelection()
            }
            .disabled(controller.timelineSelection == nil)
            ControlButton(icon: "trash", help: "Удалить выбранный клип (Delete)") {
                controller.deleteSelectedClip()
            }
            .disabled(controller.selectedClipID == nil)

            Spacer()

            Text(TimeFormat.short(controller.duration))
                .font(.system(size: Theme.TypeScale.time, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
    }
}

/// Единственный текст в панели, который обновляется вместе с позицией плеера.
private struct PlaybackTimeLabel: View {
    var controller: EditorController

    var body: some View {
        Text(TimeFormat.short(controller.currentTime))
            .font(.system(size: Theme.TypeScale.time, weight: .semibold, design: .monospaced))
            .foregroundStyle(Theme.textPrimary)
            .frame(width: 84, alignment: .leading)
    }
}

/// Кнопка изолирует частые изменения состояния Play/Pause от остальной панели.
private struct PlayPauseControl: View {
    var controller: EditorController

    var body: some View {
        ControlButton(
            icon: controller.isPlaying ? "pause.fill" : "play.fill",
            help: "Плей/пауза (пробел)", size: 22, prominent: true
        ) {
            controller.togglePlay()
        }
    }
}

private struct ControlButton: View {
    let icon: String
    let help: String
    var size: CGFloat = 15
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(prominent ? Color.white : Theme.textPrimary)
                .frame(width: prominent ? 44 : 34, height: prominent ? 44 : 34)
                .background(prominent ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.clear))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Видео-слой

/// Нативный слой воспроизведения без встроенных элементов управления.
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    var onVideoSizeChange: ((CGSize) -> Void)?

    init(player: AVPlayer, onVideoSizeChange: ((CGSize) -> Void)? = nil) {
        self.player = player
        self.onVideoSizeChange = onVideoSizeChange
    }

    func makeNSView(context: Context) -> PlayerNSView {
        let view = PlayerNSView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.onVideoSizeChange = onVideoSizeChange
        return view
    }

    func updateNSView(_ nsView: PlayerNSView, context: Context) {
        nsView.playerLayer.player = player
        nsView.onVideoSizeChange = onVideoSizeChange
        nsView.reportVideoSize()
    }
}

final class PlayerNSView: NSView {
    let playerLayer = AVPlayerLayer()
    var onVideoSizeChange: ((CGSize) -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer = playerLayer
        playerLayer.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        reportVideoSize()
    }

    func reportVideoSize() {
        let size = playerLayer.videoRect.size
        guard size.width > 0, size.height > 0 else { return }
        onVideoSizeChange?(size)
    }
}
