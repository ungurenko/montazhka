import SwiftUI
import AVFoundation
import AppKit
import UniformTypeIdentifiers

/// Монтажный стол: плеер сверху, лента снизу, справа — панель поиска пауз.
struct EditorView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var controller: EditorController
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
                if controller.showPausePanel {
                    PausePanel(controller: controller)
                        .frame(width: 300)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 16)
            .animation(.easeInOut(duration: 0.2), value: controller.showPausePanel)

            TimelineView(controller: controller)
                .frame(height: 168)
                .padding(16)
        }
        .background(Theme.background)
        .sheet(isPresented: $showExport) {
            ExportSheet(controller: controller)
        }
        .alert("Файлы не найдены", isPresented: missingAlertBinding) {
            Button("Понятно", role: .cancel) {}
        } message: {
            Text(controller.missingFilesMessage ?? "")
        }
        .onAppear {
            projectName = controller.project.name
            installKeyMonitor()
        }
        .onDisappear { removeKeyMonitor() }
    }

    private var missingAlertBinding: Binding<Bool> {
        Binding(
            get: { controller.missingFilesMessage != nil },
            set: { if !$0 { controller.missingFilesMessage = nil } }
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

            Spacer()

            Button {
                let urls = AppModel.pickVideos()
                controller.addClips(urls: urls)
            } label: {
                Label("Добавить видео", systemImage: "plus")
            }
            .buttonStyle(.bordered)

            Button {
                withAnimation { controller.showPausePanel.toggle() }
            } label: {
                Label("Найти паузы", systemImage: "waveform.badge.magnifyingglass")
            }
            .buttonStyle(.bordered)
            .tint(controller.showPausePanel ? Theme.accent : nil)

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

    // MARK: - Плеер

    private var playerArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(Color.black)
            if controller.project.clips.isEmpty {
                dropHint
            } else {
                PlayerLayerView(player: controller.player)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                    .onTapGesture { controller.togglePlay() }
            }
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
    @ObservedObject var controller: EditorController

    var body: some View {
        HStack(spacing: 18) {
            Text(TimeFormat.short(controller.currentTime))
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 84, alignment: .leading)

            Spacer()

            ControlButton(icon: "backward.frame.fill", help: "Кадр назад (←)") {
                controller.stepFrames(-1)
            }
            ControlButton(icon: controller.isPlaying ? "pause.fill" : "play.fill",
                          help: "Плей/пауза (пробел)", size: 22, prominent: true) {
                controller.togglePlay()
            }
            ControlButton(icon: "forward.frame.fill", help: "Кадр вперёд (→)") {
                controller.stepFrames(1)
            }

            Divider().frame(height: 22)

            ControlButton(icon: "scissors", help: "Разрезать по курсору (S)") {
                controller.splitAtPlayhead()
            }
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
