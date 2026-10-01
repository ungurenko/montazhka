#if DEBUG
    import SwiftUI

    @MainActor
    private enum PreviewFixtures {
        static func editor(_ section: EditorInspectorSection? = nil) -> (
            PreviewEnvironment, AppModel, EditorController
        ) {
            let environment = PreviewEnvironment()
            var project = Project(name: "Демо-проект")
            project.voiceEnhance.enabled = section == .voice
            let controller = EditorController(
                project: project,
                store: environment.repository,
                openRouterKeyStore: EmptyOpenRouterKeyStore(),
                preferences: environment.preferences,
                activity: environment.activity,
                isPreview: true,
                aiConnection: environment.makeAIConnection(reasoningKey: EditorController.smartEditReasoningKey))
            controller.activeInspector = section
            return (environment, AppModel(store: environment.repository, isPreview: true), controller)
        }

        static func shorts() -> (PreviewEnvironment, AppModel, ShortsController) {
            let environment = PreviewEnvironment()
            let sourceURL = environment.repository.root.appendingPathComponent("Демо.mov")
            let controller = ShortsController(
                sourceURL: sourceURL,
                store: environment.repository,
                openRouterKeyStore: EmptyOpenRouterKeyStore(),
                preferences: environment.preferences,
                activity: environment.activity,
                isPreview: true,
                aiConnection: environment.makeAIConnection(reasoningKey: ShortsController.reasoningKey),
                previewSourceDuration: 120)
            controller.candidates = [
                ShortCandidate(
                    id: UUID(), rank: 1, title: "Почему быстрый монтаж важен",
                    reason: "Сильное начало, законченная мысль и понятная польза.",
                    hook: "Зритель решает за первые три секунды", pattern: "практика",
                    excerpt: "Первые секунды определяют, останется ли человек смотреть ролик дальше.",
                    start: 12, end: 46, confidence: 0.94,
                    hookScore: 9, standaloneScore: 9, payoffScore: 8, pacingScore: 8,
                    enabled: true),
                ShortCandidate(
                    id: UUID(), rank: 2, title: "Как убрать лишнее из ролика",
                    reason: "Практический совет, который работает отдельно от интервью.",
                    hook: "Самая частая ошибка — оставить всё", pattern: "совет",
                    excerpt: "Если фрагмент не двигает мысль вперёд, зрителю он тоже не нужен.",
                    start: 58, end: 91, confidence: 0.88,
                    hookScore: 8, standaloneScore: 8, payoffScore: 9, pacingScore: 7,
                    enabled: true),
            ]
            return (environment, AppModel(store: environment.repository, isPreview: true), controller)
        }
    }

    @MainActor
    struct StartViewPreview: PreviewProvider {
        static var previews: some View {
            let environment = PreviewEnvironment()
            return StartView()
                .environment(AppModel(store: environment.repository, isPreview: true))
                .environment(environment.activity)
                .frame(width: 1080, height: 660)
                .preferredColorScheme(.light)
        }
    }

    @MainActor
    struct EditorViewPreview: PreviewProvider {
        static var previews: some View {
            let (environment, app, controller) = PreviewFixtures.editor()
            return EditorView(controller: controller)
                .environment(app)
                .environment(environment.activity)
                .frame(width: 1180, height: 720)
                .preferredColorScheme(.light)
        }
    }

    @MainActor
    struct EditorInspectorPreviews: PreviewProvider {
        static var previews: some View {
            ForEach(
                [
                    EditorInspectorSection.pauses,
                    .smartEdit,
                    .voice,
                    .music,
                ],
                id: \.rawValue
            ) { section in
                let (environment, app, controller) = PreviewFixtures.editor(section)
                EditorView(controller: controller)
                    .environment(app)
                    .environment(environment.activity)
                    .frame(width: 1280, height: 720)
                    .preferredColorScheme(.light)
                    .previewDisplayName("Панель: \(section.rawValue)")
            }
        }
    }

    @MainActor
    struct ExportSheetPreview: PreviewProvider {
        static var previews: some View {
            let (environment, _, controller) = PreviewFixtures.editor()
            ExportSheet(controller: controller, activity: environment.activity)
                .environment(environment.activity)
                .preferredColorScheme(.light)
                .previewDisplayName("Экспорт")
        }
    }

    @MainActor
    struct ShortsViewPreview: PreviewProvider {
        static var previews: some View {
            let (environment, app, controller) = PreviewFixtures.shorts()
            ShortsView(controller: controller)
                .environment(app)
                .environment(environment.activity)
                .frame(width: 1280, height: 720)
                .preferredColorScheme(.light)
                .previewDisplayName("Shorts")
        }
    }
#endif
