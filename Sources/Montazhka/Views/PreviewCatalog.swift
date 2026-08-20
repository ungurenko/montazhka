#if DEBUG
    import SwiftUI

    @MainActor
    private enum PreviewFixtures {
        static func repository(_ name: String) -> ProjectStore {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("montazhka-preview-\(name)", isDirectory: true)
            return ProjectStore(baseDirectory: root)
        }
    }

    @MainActor
    struct StartViewPreview: PreviewProvider {
        static var previews: some View {
            StartView()
                .environment(AppModel(store: PreviewFixtures.repository("start")))
                .frame(width: 1080, height: 660)
                .preferredColorScheme(.light)
        }
    }

    @MainActor
    struct EditorViewPreview: PreviewProvider {
        static var previews: some View {
            let store = PreviewFixtures.repository("editor")
            let controller = EditorController(
                project: Project(name: "Демо-проект"),
                store: store,
                openRouterKeyStore: EmptyOpenRouterKeyStore()
            )
            return EditorView(controller: controller)
                .environment(AppModel(store: store))
                .frame(width: 1180, height: 720)
                .preferredColorScheme(.light)
        }
    }
#endif
