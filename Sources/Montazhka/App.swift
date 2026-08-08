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
    @Published var storeErrorMessage: String?

    init() {
        refreshRecents()
        // Отладочный режим: сразу открыть последний проект
        if CommandLine.arguments.contains("--open-latest"), let latest = recents.first {
            openProject(id: latest.id)
        }
    }

    func refreshRecents() {
        do {
            let listing = try store.listProjects()
            recents = listing.projects
            if listing.issues.isEmpty {
                storeErrorMessage = nil
            } else {
                let count = listing.issues.count
                let names = listing.issues.prefix(3).map(\.fileName).joined(separator: ", ")
                storeErrorMessage = "Не удалось открыть \(count) \(count == 1 ? "проект" : "проекта"): \(names). Остальные проекты доступны."
            }
        } catch {
            storeErrorMessage = error.localizedDescription
        }
    }

    func newProject(with urls: [URL]) {
        var project = Project(name: ProjectStore.defaultProjectName())
        do {
            try store.save(project)
        } catch {
            storeErrorMessage = error.localizedDescription
            return
        }
        project.updatedAt = Date()
        let controller = EditorController(project: project, store: store)
        controller.addClips(urls: urls)
        editor = controller
    }

    func openProject(id: UUID) {
        do {
            let project = try store.load(id: id)
            editor = EditorController(project: project, store: store)
        } catch {
            storeErrorMessage = error.localizedDescription
        }
    }

    func deleteProject(id: UUID) {
        do {
            try store.delete(id: id)
            refreshRecents()
        } catch {
            storeErrorMessage = error.localizedDescription
        }
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
        .alert("Ошибка проекта", isPresented: storeErrorBinding) {
            Button("Понятно", role: .cancel) {}
        } message: {
            Text(app.storeErrorMessage ?? "")
        }
    }

    private var storeErrorBinding: Binding<Bool> {
        Binding(
            get: { app.storeErrorMessage != nil },
            set: { if !$0 { app.storeErrorMessage = nil } }
        )
    }
}
