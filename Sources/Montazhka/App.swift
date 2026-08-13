import SwiftUI
import AppKit
import OSLog

struct MontazhkaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
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
@Observable
final class AppModel {
    let store: ProjectStore
    var editor: EditorController?
    var recents: [ProjectMeta] = []
    var storeErrorMessage: String?
    private var recentsTask: Task<Void, Never>?
    private var recentsGeneration = 0

    init(store: ProjectStore = ProjectStore()) {
        self.store = store
        refreshRecents(openLatestAfterLoad: CommandLine.arguments.contains("--open-latest"))
    }

    func refreshRecents(openLatestAfterLoad: Bool = false) {
        recentsTask?.cancel()
        recentsGeneration += 1
        let generation = recentsGeneration
        recentsTask = Task { [weak self] in
            guard let self else { return }
            do {
                let listing = try await store.listProjects()
                guard !Task.isCancelled, generation == recentsGeneration else { return }
                recents = listing.projects
                if listing.issues.isEmpty {
                    storeErrorMessage = nil
                } else {
                    let count = listing.issues.count
                    let names = listing.issues.prefix(3).map(\.fileName).joined(separator: ", ")
                    storeErrorMessage = "Не удалось открыть \(count) \(count == 1 ? "проект" : "проекта"): \(names). Остальные проекты доступны."
                }
                if openLatestAfterLoad, editor == nil, let latest = recents.first {
                    await openProject(id: latest.id)
                }
            } catch {
                guard !Task.isCancelled, generation == recentsGeneration else { return }
                Logger.persistence.error("Не удалось получить список проектов: \(error.localizedDescription)")
                storeErrorMessage = error.localizedDescription
            }
        }
    }

    func newProject(with urls: [URL]) async {
        var project = Project(name: ProjectStore.defaultProjectName())
        do {
            try await store.saveAsync(project)
        } catch {
            Logger.persistence.error("Не удалось создать проект: \(error.localizedDescription)")
            storeErrorMessage = error.localizedDescription
            return
        }
        project.updatedAt = Date()
        let controller = EditorController(project: project, store: store)
        controller.addClips(urls: urls)
        editor = controller
    }

    func openProject(id: UUID) async {
        do {
            let project = try await store.loadAsync(id: id)
            editor = EditorController(project: project, store: store)
        } catch {
            storeErrorMessage = error.localizedDescription
        }
    }

    func deleteProject(id: UUID) async {
        do {
            try await store.deleteAsync(id: id)
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
    @Environment(AppModel.self) private var app

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
