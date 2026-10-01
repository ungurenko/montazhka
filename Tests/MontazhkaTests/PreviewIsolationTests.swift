#if DEBUG
    import Foundation
    import Testing

    @testable import MontazhkaKit

    @Suite
    @MainActor
    struct PreviewIsolationTests {
        @Test
        func editorPreviewKeepsEditsWithoutBackgroundMediaOrPersistence() async throws {
            let environment = PreviewEnvironment()
            let calls = PreviewMediaCalls()
            let source = environment.repository.root.appendingPathComponent("source.mov")
            var project = Project(name: "Preview", clips: [Clip(sourcePath: source.path, start: 0, end: 5)])
            project.voiceEnhance.enabled = true
            let connection = environment.makeAIConnection(reasoningKey: EditorController.smartEditReasoningKey)
            let controller = EditorController(
                project: project,
                store: environment.repository,
                openRouterKeyStore: EmptyOpenRouterKeyStore(),
                preferences: environment.preferences,
                activity: environment.activity,
                isPreview: true,
                aiConnection: connection,
                readClip: { index, url in
                    calls.record()
                    return ClipLoadResult(index: index, url: url, duration: nil, error: nil)
                },
                voiceRender: { _, _, _, _ in calls.record() })
            let app = AppModel(store: environment.repository, isPreview: true)

            controller.rebuildAndSeek(to: 0)
            controller.renameProject("Updated preview")
            var voice = controller.project.voiceEnhance
            voice.presence = 0.7
            controller.updateVoiceSettings(voice)
            let size = await controller.sourceDisplaySize()
            connection.refreshAgents(force: true)
            try await Task.sleep(for: .milliseconds(850))

            #expect(controller.project.name == "Updated preview")
            #expect(controller.project.voiceEnhance.presence == 0.7)
            #expect(controller.missingFilesMessage == nil)
            #expect(controller.player.currentItem == nil)
            #expect(size == nil)
            #expect(calls.callCount == 0)
            #expect(environment.repository.accessCount == 0)
            #expect(!FileManager.default.fileExists(atPath: environment.repository.root.path))
            #expect(app.recents.isEmpty)
            #expect(connection.agents == PreviewEnvironment.agents)
            #expect(connection.agents.allSatisfy { $0.executablePath == nil })
            await controller.stop()
        }

        @Test
        func shortsPreviewUsesPreparedDurationAndNeverBuildsMedia() async throws {
            let environment = PreviewEnvironment()
            let builder = ForbiddenPreviewBuilder()
            let controller = ShortsController(
                sourceURL: environment.repository.root.appendingPathComponent("source.mov"),
                store: environment.repository,
                openRouterKeyStore: EmptyOpenRouterKeyStore(),
                previewBuilder: builder,
                preferences: environment.preferences,
                activity: environment.activity,
                isPreview: true,
                aiConnection: environment.makeAIConnection(reasoningKey: ShortsController.reasoningKey),
                previewSourceDuration: 120)
            let candidate = ShortCandidate(
                id: UUID(), rank: 1, title: "Preview", reason: "", hook: "", pattern: "",
                excerpt: "", start: 0, end: 5, confidence: 1,
                hookScore: 10, standaloneScore: 10, payoffScore: 10, pacingScore: 10, enabled: true)
            controller.candidates = [candidate]

            controller.prepare()
            controller.preview(candidate)
            try await Task.sleep(for: .milliseconds(30))

            #expect(controller.sourceDuration == 120)
            #expect(controller.prepareError == nil)
            #expect(controller.previewDuration == 5)
            #expect(controller.player.currentItem == nil)
            #expect(builder.calls == 0)
            #expect(environment.repository.accessCount == 0)
            #expect(!FileManager.default.fileExists(atPath: environment.repository.root.path))
            await controller.shutdown()
        }
    }

    private final class PreviewMediaCalls: @unchecked Sendable {
        private let lock = NSLock()
        private var storedCount = 0
        var callCount: Int { lock.withLock { storedCount } }
        func record() { lock.withLock { storedCount += 1 } }
    }

    @MainActor
    private final class ForbiddenPreviewBuilder: ShortsPreviewBuilding {
        private(set) var calls = 0

        func makeItem(for request: ShortsPreviewRequest) async throws -> ShortsPreviewItem {
            calls += 1
            throw CancellationError()
        }
    }
#endif
