#if DEBUG
    import SwiftUI

    @MainActor
    private enum PreviewFixtures {
        static func repository(_ name: String) -> ProjectStore {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("montazhka-preview-\(name)", isDirectory: true)
            return ProjectStore(baseDirectory: root)
        }

        static func editor(_ section: EditorInspectorSection? = nil) -> (AppModel, EditorController) {
            let store = repository("editor-\(section?.rawValue ?? "base")")
            let controller = EditorController(
                project: Project(name: "Демо-проект"),
                store: store,
                openRouterKeyStore: EmptyOpenRouterKeyStore()
            )
            controller.activeInspector = section
            return (AppModel(store: store), controller)
        }

        static func shorts() -> (AppModel, ShortsController) {
            let store = repository("shorts")
            let sourceURL = store.directories.projects.appendingPathComponent("Интервью.mov")
            let controller = ShortsController(
                sourceURL: sourceURL,
                store: store,
                openRouterKeyStore: EmptyOpenRouterKeyStore())
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
            return (AppModel(store: store), controller)
        }
    }

    @MainActor
    struct StartViewPreview: PreviewProvider {
        static var previews: some View {
            StartView()
                .environment(AppModel(store: PreviewFixtures.repository("start")))
                .environment(ActivityCenter.shared)
                .frame(width: 1080, height: 660)
                .preferredColorScheme(.light)
        }
    }

    @MainActor
    struct EditorViewPreview: PreviewProvider {
        static var previews: some View {
            let (app, controller) = PreviewFixtures.editor()
            return EditorView(controller: controller)
                .environment(app)
                .environment(ActivityCenter.shared)
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
                let (app, controller) = PreviewFixtures.editor(section)
                EditorView(controller: controller)
                    .environment(app)
                    .environment(ActivityCenter.shared)
                    .frame(width: 1280, height: 720)
                    .preferredColorScheme(.light)
                    .previewDisplayName("Панель: \(section.rawValue)")
            }
        }
    }

    @MainActor
    struct ExportSheetPreview: PreviewProvider {
        static var previews: some View {
            let (_, controller) = PreviewFixtures.editor()
            ExportSheet(controller: controller)
                .preferredColorScheme(.light)
                .previewDisplayName("Экспорт")
        }
    }

    @MainActor
    struct ShortsViewPreview: PreviewProvider {
        static var previews: some View {
            let (app, controller) = PreviewFixtures.shorts()
            ShortsView(controller: controller)
                .environment(app)
                .environment(ActivityCenter.shared)
                .frame(width: 1280, height: 720)
                .preferredColorScheme(.light)
                .previewDisplayName("Shorts")
        }
    }
#endif
