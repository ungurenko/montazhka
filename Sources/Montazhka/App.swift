import SwiftUI
import AppKit

struct MontazhkaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .frame(minWidth: 1080, minHeight: 660)
                .preferredColorScheme(.light)
                .background(Theme.background)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            // Меню не умеет следить за состоянием редактора (canUndo живёт в другом объекте),
            // поэтому пункты всегда активны, а пустая отмена — просто ничего не делает.
            CommandGroup(replacing: .undoRedo) {
                Button("Отменить") { app.editor?.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                Button("Повторить") { app.editor?.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Всегда светлый интерфейс — как просил Александр.
        NSApp.appearance = NSAppearance(named: .aqua)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Навигация приложения: стартовый экран или монтажный стол.
@MainActor
final class AppModel: ObservableObject {
    let store = ProjectStore()
    @Published var editor: EditorController?
    @Published var recents: [ProjectMeta] = []

    init() {
        refreshRecents()
        // Отладочный режим: сразу открыть последний проект
        if CommandLine.arguments.contains("--open-latest"), let latest = recents.first {
            openProject(id: latest.id)
        }
    }

    func refreshRecents() {
        recents = store.listProjects()
    }

    func newProject(with urls: [URL]) {
        var project = Project(name: ProjectStore.defaultProjectName())
        store.save(project)
        project.updatedAt = Date()
        let controller = EditorController(project: project, store: store)
        controller.addClips(urls: urls)
        editor = controller
    }

    func openProject(id: UUID) {
        guard let project = store.load(id: id) else { return }
        editor = EditorController(project: project, store: store)
    }

    func deleteProject(id: UUID) {
        store.delete(id: id)
        refreshRecents()
    }

    func closeProject() {
        editor?.shutdown()
        editor = nil
        refreshRecents()
    }

    /// Системное окно выбора видеофайлов.
    static func pickVideos() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "Выбери видео"
        panel.prompt = "Добавить"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        return panel.runModal() == .OK ? panel.urls : []
    }
}

struct RootView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if let editor = app.editor {
                EditorView(controller: editor)
                    .transition(.opacity)
            } else {
                StartView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: app.editor == nil)
    }
}
