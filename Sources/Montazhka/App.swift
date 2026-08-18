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
        // Запуск из терминала (swift run) не выводит окно вперёд — активируем сами.
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Навигация приложения: стартовый экран, монтажный стол или нарезка на shorts.
@MainActor
@Observable
final class AppModel {
    let store: any ProjectRepository
    var editor: EditorController?
    var shorts: ShortsController?
    var recents: [ProjectMeta] = []
    var storeErrorMessage: String?
    private(set) var isProjectOperationInProgress = false
    private var recentsTask: Task<Void, Never>?
    private var recentsGeneration = 0
    private var projectOperationTask: Task<Void, Never>?
    private var projectOperationGeneration = Generation()

    init(store: any ProjectRepository = ProjectStore()) {
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
                    openProject(id: latest.id)
                }
            } catch {
                guard !Task.isCancelled, generation == recentsGeneration else { return }
                Logger.persistence.error("Не удалось получить список проектов: \(error.localizedDescription)")
                storeErrorMessage = error.localizedDescription
            }
        }
    }

    func newProject(with urls: [URL]) {
        let generation = beginProjectOperation()
        projectOperationTask = Task { [weak self] in
            guard let self else { return }
            var project = Project(name: ProjectStore.defaultProjectName())
            do {
                try await store.save(project)
                guard isCurrentProjectOperation(generation) else { return }
                project.updatedAt = Date()
                let controller = EditorController(project: project, store: store)
                controller.addClips(urls: urls)
                editor = controller
                finishProjectOperation(generation)
            } catch {
                failProjectOperation(generation, error: error, context: "Не удалось создать проект")
            }
        }
    }

    func openProject(id: UUID) {
        let generation = beginProjectOperation()
        projectOperationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let project = try await store.load(id: id)
                guard isCurrentProjectOperation(generation) else { return }
                editor = EditorController(project: project, store: store)
                finishProjectOperation(generation)
            } catch {
                failProjectOperation(generation, error: error, context: "Не удалось открыть проект")
            }
        }
    }

    func deleteProject(id: UUID) {
        let generation = beginProjectOperation()
        projectOperationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await store.delete(id: id)
                guard isCurrentProjectOperation(generation) else { return }
                finishProjectOperation(generation)
                refreshRecents()
            } catch {
                failProjectOperation(generation, error: error, context: "Не удалось удалить проект")
            }
        }
    }

    func closeProject() {
        guard let closingEditor = editor else { return }
        let generation = beginProjectOperation()
        projectOperationTask = Task { [weak self] in
            guard let self else { return }
            await closingEditor.shutdown()
            guard isCurrentProjectOperation(generation) else { return }
            editor = nil
            finishProjectOperation(generation)
            refreshRecents()
        }
    }

    // MARK: - Нарезка на shorts

    func startShorts(url: URL) {
        let generation = beginProjectOperation()
        projectOperationTask = Task { [weak self] in
            guard let self else { return }
            guard isCurrentProjectOperation(generation) else { return }
            let controller = ShortsController(sourceURL: url, store: store)
            shorts = controller
            controller.prepare()
            finishProjectOperation(generation)
        }
    }

    func closeShorts() {
        guard let closingShorts = shorts else { return }
        let generation = beginProjectOperation()
        projectOperationTask = Task { [weak self] in
            guard let self else { return }
            await closingShorts.shutdown()
            guard isCurrentProjectOperation(generation) else { return }
            shorts = nil
            finishProjectOperation(generation)
        }
    }

    private func beginProjectOperation() -> Int {
        projectOperationTask?.cancel()
        recentsTask?.cancel()
        recentsGeneration += 1
        storeErrorMessage = nil
        isProjectOperationInProgress = true
        return projectOperationGeneration.advance()
    }

    private func isCurrentProjectOperation(_ generation: Int) -> Bool {
        !Task.isCancelled && projectOperationGeneration.isCurrent(generation)
    }

    private func finishProjectOperation(_ generation: Int) {
        guard projectOperationGeneration.isCurrent(generation) else { return }
        projectOperationTask = nil
        isProjectOperationInProgress = false
    }

    private func failProjectOperation(_ generation: Int, error: Error, context: String) {
        guard isCurrentProjectOperation(generation) else { return }
        Logger.persistence.error("\(context): \(error.localizedDescription)")
        storeErrorMessage = error.localizedDescription
        finishProjectOperation(generation)
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

    /// Системное окно выбора одного длинного видео для нарезки на shorts.
    static func pickVideo() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Выбери длинное видео"
        panel.prompt = "Нарезать"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        return panel.runModal() == .OK ? panel.url : nil
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app

    /// Числовой ключ режима — для плавной анимации смены экранов.
    private var rootKey: Int {
        if app.editor != nil { return 1 }
        if app.shorts != nil { return 2 }
        return 0
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if let editor = app.editor {
                EditorView(controller: editor)
                    .transition(.opacity)
            } else if let shorts = app.shorts {
                ShortsView(controller: shorts)
                    .transition(.opacity)
            } else {
                StartView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: rootKey)
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
