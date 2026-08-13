import SwiftUI
import AVFoundation
import AppKit
import UniformTypeIdentifiers

/// Монтажный стол: плеер сверху, лента снизу, справа — панель поиска пауз.
struct EditorView: View {
    @EnvironmentObject private var app: AppModel
    var controller: EditorController
    @State private var projectName: String = ""
    @State private var showExport = false
    @State private var keyMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            topBar
            HStack(spacing: 12) {
                VStack(spacing: 12) {
                    playerArea
                    TransportBar(controller: controller)
                }
                if controller.showSmartEditPanel {
                    SmartEditPanel(controller: controller)
                        .frame(width: 340)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else if controller.showMusicPanel {
                    MusicPanel(controller: controller)
                        .frame(width: 300)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else if controller.showVoicePanel {
                    VoicePanel(controller: controller)
                        .frame(width: 300)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else if controller.showPausePanel {
                    PausePanel(controller: controller)
                        .frame(width: 300)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 16)
            .animation(.easeInOut(duration: 0.2), value: controller.showPausePanel)
            .animation(.easeInOut(duration: 0.2), value: controller.showVoicePanel)
            .animation(.easeInOut(duration: 0.2), value: controller.showMusicPanel)
            .animation(.easeInOut(duration: 0.2), value: controller.showSmartEditPanel)

            TimelineView(controller: controller)
                .frame(height: 168)
                .padding(16)
        }
        .background(Theme.background)
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
            Button("Повторить") { controller.saveNow() }
            Button("Закрыть", role: .cancel) { controller.dismissSaveError() }
        } message: {
            if case let .failed(message) = controller.saveStatus {
                Text(message)
            }
        }
        .onAppear {
            projectName = controller.project.name
            installKeyMonitor()
        }
        .onDisappear { removeKeyMonitor() }
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

            TextField("Название", text: $projectName)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: 260)
                .onSubmit { controller.renameProject(projectName) }

            saveStatusView

            Spacer()

            Button {
                let urls = AppModel.pickVideos()
                controller.addClips(urls: urls)
            } label: {
                Label("Добавить видео", systemImage: "plus")
            }
            .buttonStyle(.bordered)

            Menu {
                Button {
                    withAnimation {
                        controller.showPausePanel = true
                        controller.showSmartEditPanel = false
                        controller.showVoicePanel = false
                        controller.showMusicPanel = false
                    }
                } label: {
                    Label("Найти паузы", systemImage: "waveform.badge.magnifyingglass")
                }
                Button {
                    withAnimation {
                        controller.showSmartEditPanel = true
                        controller.showPausePanel = false
                        controller.showVoicePanel = false
                        controller.showMusicPanel = false
                    }
                } label: {
                    Label("Умный монтаж", systemImage: "wand.and.sparkles")
                }
            } label: {
                Label("Чистка", systemImage: "wand.and.stars")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                withAnimation {
                    controller.showVoicePanel.toggle()
                    if controller.showVoicePanel {
                        controller.showPausePanel = false
                        controller.showMusicPanel = false
                        controller.showSmartEditPanel = false
                    }
                }
            } label: {
                Label("Улучшить голос", systemImage: "waveform.and.mic")
            }
            .buttonStyle(.bordered)
            .tint(controller.showVoicePanel || controller.project.voiceEnhance.enabled ? Theme.accent : nil)

            Button {
                withAnimation {
                    controller.showMusicPanel.toggle()
                    if controller.showMusicPanel {
                        controller.showPausePanel = false
                        controller.showVoicePanel = false
                        controller.showSmartEditPanel = false
                    }
                }
            } label: {
                Label("Музыка", systemImage: "music.note")
            }
            .buttonStyle(.bordered)
            .tint(controller.showMusicPanel || controller.project.music.enabled ? Theme.accent : nil)

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
        }
        .padding(.leading, 84) // место под «светофор» окна
        .padding(.trailing, 16)
        .padding(.vertical, 12)
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
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(Color.black)
            if controller.project.clips.isEmpty {
                dropHint
            } else if controller.previewState == .ready {
                PlayerLayerView(player: controller.player)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                    .onTapGesture { controller.togglePlay() }
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
                .font(.system(size: 15, design: .rounded))
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
                            .padding(10)
                            .background(Color.orange.opacity(0.92))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .padding(12)
                    }
                }
            }
        }
    }

    private func playerProgress(_ text: String) -> some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.regular)
                .tint(.white)
            Text(text)
                .font(.system(size: 14, weight: .medium, design: .rounded))
        }
        .foregroundStyle(.white.opacity(0.9))
    }

    private func playerError(title: String, message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
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
        let videoExtensions = Set(["mp4", "mov", "m4v", "mpg", "mpeg", "avi", "mkv"])
        var found = false
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            found = true
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                defer { group.leave() }
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let u = item as? URL {
                    url = u
                }
                if let url, videoExtensions.contains(url.pathExtension.lowercased()) {
                    lock.lock(); urls.append(url); lock.unlock()
                }
            }
        }
        group.notify(queue: .main) {
            controller.addClips(urls: urls)
        }
        return found
    }

    // MARK: - Клавиатура

    private func installKeyMonitor() {
        removeKeyMonitor()
        let controller = self.controller
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = event.keyCode
            let withShift = event.modifierFlags.contains(.shift)
            let withCommand = event.modifierFlags.contains(.command)
            let handled = MainActor.assumeIsolated { () -> Bool in
                // Не перехватываем клавиши, когда печатают текст (например, имя проекта).
                if NSApp.keyWindow?.firstResponder is NSTextView { return false }
                if withCommand { return false }

                switch keyCode {
                case 49: // пробел
                    controller.togglePlay()
                    return true
                case 1: // S / Ы — разрезать
                    controller.splitAtPlayhead()
                    return true
                case 34: // I / Ш — начало выделения
                    controller.markSelectionStart()
                    return true
                case 31: // O / Щ — конец выделения
                    controller.markSelectionEnd()
                    return true
                case 7: // X / Ч — вырезать выделение
                    controller.cutSelection()
                    return true
                case 51, 117: // Backspace / Delete — удалить выбранный клип
                    controller.deleteSelectedClip()
                    return true
                case 123: // ←
                    controller.stepFrames(withShift ? -30 : -1)
                    return true
                case 124: // →
                    controller.stepFrames(withShift ? 30 : 1)
                    return true
                default:
                    return false
                }
            }
            return handled ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}

// MARK: - Нижняя панель управления

private struct TransportBar: View {
    var controller: EditorController

    var body: some View {
        HStack(spacing: 18) {
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
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .cardStyle()
    }
}

/// Единственный текст в панели, который обновляется вместе с позицией плеера.
private struct PlaybackTimeLabel: View {
    var controller: EditorController

    var body: some View {
        Text(TimeFormat.short(controller.currentTime))
            .font(.system(size: 15, weight: .semibold, design: .monospaced))
            .foregroundStyle(Theme.textPrimary)
            .frame(width: 84, alignment: .leading)
    }
}

/// Кнопка изолирует частые изменения состояния Play/Pause от остальной панели.
private struct PlayPauseControl: View {
    var controller: EditorController

    var body: some View {
        ControlButton(icon: controller.isPlaying ? "pause.fill" : "play.fill",
                      help: "Плей/пауза (пробел)", size: 22, prominent: true) {
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
    }
}

// MARK: - Видео-слой

/// Нативный слой воспроизведения без встроенных элементов управления.
private struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerNSView {
        let view = PlayerNSView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: PlayerNSView, context: Context) {
        nsView.playerLayer.player = player
    }
}

final class PlayerNSView: NSView {
    let playerLayer = AVPlayerLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer = playerLayer
        playerLayer.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }
}
