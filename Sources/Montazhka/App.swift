import AppKit
import Foundation
import OSLog
import SwiftUI

private struct FocusedEditorControllerKey: FocusedValueKey {
    typealias Value = EditorController
}

extension FocusedValues {
    var editorController: EditorController? {
        get { self[FocusedEditorControllerKey.self] }
        set { self[FocusedEditorControllerKey.self] = newValue }
    }
}

struct MontazhkaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var app = AppModel()
    @FocusedValue(\.editorController) private var editor

    var body: some Scene {
        Window("Монтажка", id: "main") {
            RootView()
                .environment(app)
                .frame(minWidth: 1080, minHeight: 660)
                .preferredColorScheme(.light)
                .background(Theme.background)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .undoRedo) {
                Button("Отменить") { editor?.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(editor?.canUndo != true)
                Button("Повторить") { editor?.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(editor?.canRedo != true)
            }
            CommandMenu("Монтаж") {
                Button("Плей/пауза") { editor?.togglePlay() }
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(editor?.project.clips.isEmpty != false)
                Button("Кадр назад") { editor?.stepFrames(-1) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(editor?.project.clips.isEmpty != false)
                Button("Кадр вперёд") { editor?.stepFrames(1) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(editor?.project.clips.isEmpty != false)
                Button("Секунда назад") { editor?.stepFrames(-30) }
                    .keyboardShortcut(.leftArrow, modifiers: .shift)
                    .disabled(editor?.project.clips.isEmpty != false)
                Button("Секунда вперёд") { editor?.stepFrames(30) }
                    .keyboardShortcut(.rightArrow, modifiers: .shift)
                    .disabled(editor?.project.clips.isEmpty != false)
                Divider()
                Button("Разрезать") { editor?.splitAtPlayhead() }
                    .keyboardShortcut("s", modifiers: [])
                    .disabled(editor?.project.clips.isEmpty != false)
                Button("Начало выделения") { editor?.markSelectionStart() }
                    .keyboardShortcut("i", modifiers: [])
                    .disabled(editor?.project.clips.isEmpty != false)
                Button("Конец выделения") { editor?.markSelectionEnd() }
                    .keyboardShortcut("o", modifiers: [])
                    .disabled(editor?.project.clips.isEmpty != false)
                Button("Вырезать выделение") { editor?.cutSelection() }
                    .keyboardShortcut("x", modifiers: [])
                    .disabled(editor?.timelineSelection == nil)
                Button("Удалить выбранный клип") { editor?.deleteSelectedClip() }
                    .keyboardShortcut(.delete, modifiers: [])
                    .disabled(editor?.selectedClipID == nil)
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

    init(store: (any ProjectRepository)? = nil) {
        let arguments = CommandLine.arguments
        let environment = ProcessInfo.processInfo.environment
        let isUITesting =
            arguments.contains("--ui-testing")
            && environment["MONTAZHKA_UI_TEST_MODE"] == "1"
        let resolvedStore = store ?? Self.defaultStore(isUITesting: isUITesting, environment: environment)
        self.store = resolvedStore
        refreshRecents(openLatestAfterLoad: CommandLine.arguments.contains("--open-latest"))
        if isUITesting, arguments.contains("--ui-test-open-fixture-project") {
            openUITestFixtureProject(using: resolvedStore)
        } else if isUITesting, arguments.contains("--ui-test-open-empty-project") {
            newProject(with: [])
        } else if isUITesting, arguments.contains("--ui-test-open-shorts") {
            openUITestShorts(using: resolvedStore)
        }
    }

    private func openUITestFixtureProject(using store: any ProjectRepository) {
        let fixtureURL = store.directories.waveforms.appendingPathComponent("ui-test-fixture.mov")
        Task { [weak self] in
            do {
                try await TestVideoFactory.make(
                    segments: [(duration: 2, loud: true)],
                    to: fixtureURL)
                self?.newProject(with: [fixtureURL])
            } catch {
                self?.storeErrorMessage = error.localizedDescription
            }
        }
    }

    private func openUITestShorts(using store: any ProjectRepository) {
        let fixtureURL = store.directories.waveforms.appendingPathComponent("ui-test-shorts.mov")
        Task { [weak self] in
            do {
                try await TestVideoFactory.make(
                    segments: [(duration: 24, loud: true)],
                    to: fixtureURL)
                self?.startShorts(url: fixtureURL, seedUITestCandidate: true)
            } catch {
                self?.storeErrorMessage = error.localizedDescription
            }
        }
    }

    private static func defaultStore(
        isUITesting: Bool,
        environment: [String: String]
    ) -> any ProjectRepository {
        guard isUITesting else { return ProjectStore() }
        let baseDirectory: URL
        if let path = environment["MONTAZHKA_UI_TEST_DATA_DIR"], !path.isEmpty {
            baseDirectory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            baseDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "montazhka-ui-tests-\(ProcessInfo.processInfo.processIdentifier)",
                    isDirectory: true)
        }
        return ProjectStore(baseDirectory: baseDirectory)
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
                    storeErrorMessage =
                        "Не удалось открыть \(count) \(count == 1 ? "проект" : "проекта"): \(names). Остальные проекты доступны."
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

    func startShorts(url: URL, seedUITestCandidate: Bool = false) {
        let generation = beginProjectOperation()
        projectOperationTask = Task { [weak self] in
            guard let self else { return }
            guard isCurrentProjectOperation(generation) else { return }
            let controller = ShortsController(sourceURL: url, store: store)
            if seedUITestCandidate {
                controller.candidates = [Self.uiTestShortCandidate]
            }
            shorts = controller
            controller.prepare()
            finishProjectOperation(generation)
        }
    }

    private static let uiTestShortCandidate = ShortCandidate(
        id: UUID(),
        rank: 1,
        title: "Тестовый ролик",
        reason: "Локальный UI fixture",
        hook: "Проверка настроек",
        pattern: "тест",
        excerpt: "Локальные данные без сети",
        start: 0,
        end: 2,
        confidence: 1,
        hookScore: 10,
        standaloneScore: 10,
        payoffScore: 10,
        pacingScore: 10,
        enabled: true)

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
