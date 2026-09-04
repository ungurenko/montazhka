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
                .environment(ActivityCenter.shared)
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
                menuItem(.playPause) { editor?.togglePlay() }
                menuItem(.frameBack) { editor?.stepFrames(-1) }
                menuItem(.frameForward) { editor?.stepFrames(1) }
                menuItem(.secondBack) { editor?.stepFrames(-30) }
                menuItem(.secondForward) { editor?.stepFrames(30) }
                Divider()
                menuItem(.split) { editor?.splitAtPlayhead() }
                menuItem(.markIn) { editor?.markSelectionStart() }
                menuItem(.markOut) { editor?.markSelectionEnd() }
                menuItem(.cutSelection, isEnabled: editor?.timelineSelection != nil) {
                    editor?.cutSelection()
                }
                menuItem(.deleteClip, isEnabled: editor?.selectedClipID != nil) {
                    editor?.deleteSelectedClip()
                }
            }
        }
    }

    /// Пункт меню с клавишей из общего списка: название и клавиша берутся
    /// оттуда же, откуда подсказки на кнопках панели воспроизведения.
    private func menuItem(
        _ shortcut: Shortcut,
        isEnabled: Bool? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(shortcut.title, action: action)
            .keyboardShortcut(shortcut)
            .disabled(isEnabled ?? (editor?.project.clips.isEmpty != false))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Всегда светлый интерфейс — как просил Александр.
        NSApp.appearance = NSAppearance(named: .aqua)
        // Запуск из терминала (swift run) не выводит окно вперёд — активируем сами.
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Пользователь вернулся в окно — значок о готовой работе он уже увидел.
    func applicationDidBecomeActive(_ notification: Notification) {
        ActivityCenter.shared.acknowledge()
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
    var storeErrorMessage: UserFacingError?
    private(set) var isProjectOperationInProgress = false
    @ObservationIgnored private let recentsOperation = LatestOperation()
    private var projectOperationTask: Task<Void, Never>?
    private var projectOperationGeneration = Generation()
    var agentIntegration = AgentIntegrationInstaller.status()
    private(set) var isAgentIntegrationInProgress = false

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

    func connectAgents() {
        guard !isAgentIntegrationInProgress else { return }
        isAgentIntegrationInProgress = true
        Task { [weak self] in
            guard let self else { return }
            do { agentIntegration = try await AgentIntegrationInstaller.install() } catch {
                agentIntegration = AgentIntegrationStatus(
                    installed: false,
                    message: UserFacingError.make(error, context: .project).message)
            }
            isAgentIntegrationInProgress = false
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
                self?.storeErrorMessage = UserFacingError.make(error, context: .project)
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
                self?.storeErrorMessage = UserFacingError.make(error, context: .project)
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
        recentsOperation.start { [weak self] token in
            guard let self else { return }
            do {
                let listing = try await store.listProjects()
                guard recentsOperation.isCurrent(token) else { return }
                recents = listing.projects
                if listing.issues.isEmpty {
                    storeErrorMessage = nil
                } else {
                    let count = listing.issues.count
                    let names = listing.issues.prefix(3).map(\.fileName).joined(separator: ", ")
                    storeErrorMessage = UserFacingError(
                        "Не удалось открыть \(count) \(count == 1 ? "проект" : "проекта"): \(names).",
                        hint: "Остальные проекты доступны — эти файлы, похоже, повреждены.")
                }
                if openLatestAfterLoad, editor == nil, let latest = recents.first {
                    openProject(id: latest.id)
                }
            } catch {
                guard recentsOperation.isCurrent(token) else { return }
                storeErrorMessage = UserFacingError.make(error, context: .project)
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
        recentsOperation.cancel()
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
        Logger.persistence.error("\(context, privacy: .public)")
        storeErrorMessage = UserFacingError.make(error, context: .project)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        .animation(Theme.Motion.adapting(Theme.Motion.screen, reduceMotion: reduceMotion), value: rootKey)
        .alert(app.storeErrorMessage?.what ?? "Ошибка проекта", isPresented: storeErrorBinding) {
            Button("Понятно", role: .cancel) {}
        } message: {
            Text(app.storeErrorMessage?.hint ?? "")
        }
    }

    private var storeErrorBinding: Binding<Bool> {
        Binding(
            get: { app.storeErrorMessage != nil },
            set: { if !$0 { app.storeErrorMessage = nil } }
        )
    }
}
