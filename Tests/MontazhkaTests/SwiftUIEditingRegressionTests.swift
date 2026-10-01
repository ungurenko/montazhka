#if DEBUG
    import AppKit
    import Testing

    @testable import MontazhkaKit

    @MainActor
    @Suite("SwiftUI editing preserves current project state")
    struct SwiftUIEditingRegressionTests {
        @Test("two frame actions both apply, and stopping cancels pending frame actions")
        func frameActionsRespectLifecycle() async throws {
            let environment = PreviewEnvironment()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("frame-trim-\(UUID()).mov")
            defer {
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: environment.repository.root)
            }
            try await TestVideoFactory.make(segments: [(duration: 2, loud: true)], to: url)
            let clip = Clip(sourcePath: url.path, start: 0, end: 2)
            let controller = EditorController(
                project: Project(name: "Frames", clips: [clip]), store: environment.repository,
                openRouterKeyStore: EmptyOpenRouterKeyStore(), preferences: environment.preferences,
                activity: environment.activity,
                aiConnection: environment.makeAIConnection(reasoningKey: "frames.reasoning"))
            controller.trimOneFrame(clipID: clip.id, edge: .start)
            controller.trimOneFrame(clipID: clip.id, edge: .start)
            for _ in 0..<100 {
                if abs(controller.project.clips[0].start - 0.2) < 0.0001 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(abs(controller.project.clips[0].start - 0.2) < 0.0001)
            let beforeStop = controller.project
            controller.trimOneFrame(clipID: clip.id, edge: .end)
            await controller.stop()
            controller.trimOneFrame(clipID: clip.id, edge: .end)
            try await Task.sleep(for: .milliseconds(50))
            #expect(controller.project == beforeStop)
        }

        private func controller(_ project: Project, environment: PreviewEnvironment) -> EditorController {
            EditorController(
                project: project, store: environment.repository,
                preferences: environment.preferences, activity: environment.activity,
                isPreview: true,
                aiConnection: environment.makeAIConnection(reasoningKey: "test.reasoning"))
        }

        @Test("existing panel bindings follow undo, redo, and external updates without restoring stale fields")
        func settingsStayCurrent() async throws {
            let environment = PreviewEnvironment()
            let project = Project(name: "Settings")
            let controller = controller(project, environment: environment)
            let voice = VoicePanel(controller: controller)
            let music = MusicPanel(controller: controller)
            let pauses = PausePanel(controller: controller)
            let level = voice.setting(\.leveling)
            let volume = music.setting(\.volume)
            let threshold = pauses.setting(\.thresholdDB)

            level.wrappedValue = 80
            level.wrappedValue = 90
            controller.undo()
            #expect(level.wrappedValue == project.voiceEnhance.leveling)
            #expect(!controller.canUndo)
            controller.redo()
            #expect(level.wrappedValue == 90)

            var external = controller.project
            external.voiceEnhance.presence = 71
            external.music.ducking = false
            external.music.eqEnabled = false
            external.detection.paddingMS = 325
            try await environment.repository.save(external)
            await controller.reloadChangedProject(lostLocalEdit: false)
            level.wrappedValue = 42
            volume.wrappedValue = 25
            threshold.wrappedValue = -37
            #expect(controller.project.voiceEnhance.presence == 71)
            #expect(!controller.project.music.ducking && !controller.project.music.eqEnabled)
            #expect(controller.project.detection.paddingMS == 325)
            await controller.stop()
        }

        @Test("hover and cancellation do not edit the document; a drop creates exactly one undo")
        func reorderCommitsOnce() async {
            let environment = PreviewEnvironment()
            let clips = (0..<3).map { Clip(sourcePath: "/tmp/clip-\($0).mov", start: 0, end: 2) }
            let controller = controller(Project(name: "Drag", clips: clips), environment: environment)
            var session = TimelineReorderSession(clipID: clips[0].id, clips: clips)!
            session.move(over: clips[1].id)
            session.move(over: clips[2].id)
            #expect(controller.project.clips == clips)
            #expect(!controller.canUndo)
            // Никакая запись проекта не требуется для отмены временной сессии.
            let cancelled = session
            #expect(cancelled.originalClips == controller.project.clips)
            #expect(environment.repository.accessCount == 0)
            controller.commitReorder(session.previewClips, expectedClips: session.originalClips)
            #expect(controller.project.clips == [clips[1], clips[2], clips[0]])
            controller.undo()
            #expect(controller.project.clips == clips && !controller.canUndo)
            controller.redo()
            #expect(controller.project.clips == session.previewClips)
            await controller.stop()
        }

        @Test("a stale drag cannot overwrite a concurrent trim or delete")
        func reorderRejectsStaleSnapshot() async {
            let environment = PreviewEnvironment()
            let clips = (0..<3).map { Clip(sourcePath: "/tmp/clip-\($0).mov", start: 0, end: 2) }
            let controller = controller(Project(name: "Drag", clips: clips), environment: environment)
            var session = TimelineReorderSession(clipID: clips[0].id, clips: clips)!
            session.move(over: clips[2].id)
            controller.commitTrim(clipID: clips[1].id, edge: .end, sourceTime: 1)
            let fresh = controller.project.clips
            controller.commitReorder(session.previewClips, expectedClips: session.originalClips)
            #expect(controller.project.clips == fresh)
            controller.undo()
            #expect(controller.project.clips == clips && !controller.canUndo)
            controller.deleteClip(id: clips[2].id)
            controller.commitReorder(session.previewClips, expectedClips: session.originalClips)
            #expect(controller.project.clips == Array(clips.prefix(2)))
            await controller.stop()
        }
    }
#endif
