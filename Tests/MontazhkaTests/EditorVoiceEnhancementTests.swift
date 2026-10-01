import Foundation
import Observation
import Testing

@testable import MontazhkaKit

@MainActor
@Suite
struct EditorVoiceEnhancementTests {
    @Test("a bookmark resolving a symlink reuses ready audio in preview and export")
    func bookmarkAliasReusesReadyAudio() async throws {
        try await EditorBackgroundWorkFixture.run { fixture in
            let video = try await fixture.video()
            let alias = fixture.root.appendingPathComponent("alias", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.root)
            let reference = MediaReference(url: alias.appendingPathComponent(video.lastPathComponent))
            var project = Project(name: "Закладка", clips: [Clip(source: reference, start: 0, end: 1)])
            project.voiceEnhance = VoiceEnhanceSettings(enabled: true, leveling: 20)
            #expect(reference.lastKnownPath != project.clips[0].sourcePath)
            let gate = fixture.gate()
            let controller = fixture.editor(project: project, render: gate.voiceRender())
            try await gate.waitForStart("voice-20.0")
            await gate.open("voice-20.0")
            try await EditorBackgroundWorkFixture.waitUntil { controller.voiceStatus == .idle }

            let preview = await controller.renderComposition(project, mode: .preview, speechRanges: nil)
            let previewURLs = try await EditorBackgroundWorkFixture.audioSources(in: preview.composition)
            #expect(!previewURLs.isEmpty && previewURLs.allSatisfy { $0.pathExtension == "caf" })
            let exported = await controller.compositionForExport(project, speechRanges: nil)
            let exportURLs = try await EditorBackgroundWorkFixture.audioSources(in: exported.composition)
            #expect(exportURLs == previewURLs)
            #expect(await gate.started.count == 1)
        }
    }

    @Test("voice progress is observable and the same ready cache is used by preview and export")
    func readyAudioAndObservation() async throws {
        try await EditorBackgroundWorkFixture.run { fixture in
            let video = try await fixture.video()
            let project = fixture.voiceProject(video)
            let gate = fixture.gate()
            let controller = fixture.editor(project: project, render: gate.voiceRender())
            try await gate.waitForStart("voice-20.0")
            #expect(controller.voiceStatus == .rendering(done: 0, total: 1))
            let original = await controller.renderComposition(project, mode: .preview, speechRanges: nil)
            #expect(
                try await EditorBackgroundWorkFixture.audioSources(in: original.composition).allSatisfy {
                    $0.pathExtension == "mov"
                })
            let flag = EditorObservationFlag()
            withObservationTracking {
                _ = controller.voiceStatus
            } onChange: {
                flag.markChanged()
            }

            await gate.open("voice-20.0")
            try await EditorBackgroundWorkFixture.waitUntil { controller.voiceStatus == .idle }
            #expect(flag.changed)
            let preview = await controller.renderComposition(project, mode: .preview, speechRanges: nil)
            let previewURLs = try await EditorBackgroundWorkFixture.audioSources(in: preview.composition)
            #expect(!previewURLs.isEmpty)
            let renderedSources = await gate.voiceSources
            #expect(
                previewURLs.allSatisfy { $0.pathExtension == "caf" },
                "preview: \(previewURLs); rendered: \(renderedSources); clip: \(project.clips[0].sourcePath)")
            let exported = await controller.compositionForExport(project, speechRanges: nil)
            let exportURLs = try await EditorBackgroundWorkFixture.audioSources(in: exported.composition)
            #expect(exportURLs == previewURLs, "export: \(exportURLs); warning: \(exported.audioWarning ?? "none")")
            let renders = await gate.started
            #expect(renders == ["voice-20.0"], "renders: \(renders)")
        }
    }

    @Test("slider changes use the last settings, keep old ready audio and undo as one edit")
    func sliderChangesKeepPreviousAudio() async throws {
        try await EditorBackgroundWorkFixture.run { fixture in
            let video = try await fixture.video()
            let gate = fixture.gate()
            let controller = fixture.editor(project: fixture.voiceProject(video), render: gate.voiceRender())
            try await gate.waitForStart("voice-20.0")
            await gate.open("voice-20.0")
            try await EditorBackgroundWorkFixture.waitUntil { controller.voiceStatus == .idle }
            let previous = await controller.renderComposition(controller.project, mode: .preview, speechRanges: nil)
            let previousURLs = try await EditorBackgroundWorkFixture.audioSources(in: previous.composition)

            for level in [30.0, 50.0, 80.0] {
                controller.updateVoiceSettings(VoiceEnhanceSettings(enabled: true, leveling: level))
            }
            try await gate.waitForStart("voice-80.0")
            #expect(await gate.started == ["voice-20.0", "voice-80.0"])
            let pending = await controller.renderComposition(controller.project, mode: .preview, speechRanges: nil)
            #expect(try await EditorBackgroundWorkFixture.audioSources(in: pending.composition) == previousURLs)

            await gate.open("voice-80.0")
            try await EditorBackgroundWorkFixture.waitUntil { controller.voiceStatus == .idle }
            let refreshed = await controller.renderComposition(controller.project, mode: .preview, speechRanges: nil)
            #expect(try await EditorBackgroundWorkFixture.audioSources(in: refreshed.composition) != previousURLs)
            controller.undo()
            #expect(controller.project.voiceEnhance.leveling == 20)
            #expect(!controller.canUndo)
        }
    }

    @Test("missing audio falls back quietly; a render failure reports the unchanged error", arguments: [false, true])
    func audioFallback(failing: Bool) async throws {
        try await EditorBackgroundWorkFixture.run { fixture in
            let video = try await fixture.video()
            let gate = fixture.gate()
            let controller = fixture.editor(
                project: fixture.voiceProject(video),
                render: gate.voiceRender(failing: [20: failing ? .renderFailed : .noAudioTrack]))
            try await gate.waitForStart("voice-20.0")
            await gate.open("voice-20.0")
            try await EditorBackgroundWorkFixture.waitUntil {
                controller.voiceStatus != .rendering(done: 0, total: 1)
            }
            if failing {
                #expect(
                    controller.voiceStatus
                        == .failed(
                            UserFacingError(
                                "Не получилось обработать звук.", hint: "Просмотр и экспорт пойдут с исходным звуком."))
                )
            } else {
                #expect(controller.voiceStatus == .idle)
            }
            let result = await controller.renderComposition(controller.project, mode: .preview, speechRanges: nil)
            #expect(
                try await EditorBackgroundWorkFixture.audioSources(in: result.composition).allSatisfy {
                    $0.pathExtension == "mov"
                })
        }
    }

    @Test("a late failure from an old render cannot clear the new ready audio or its status")
    func lateFailureCannotReplaceCurrentResult() async throws {
        try await EditorBackgroundWorkFixture.run { fixture in
            let video = try await fixture.video()
            let gate = fixture.gate()
            let controller = fixture.editor(
                project: fixture.voiceProject(video), render: gate.voiceRender(failing: [20: .renderFailed]))
            try await gate.waitForStart("voice-20.0")
            controller.updateVoiceSettings(VoiceEnhanceSettings(enabled: true, leveling: 80))
            try await gate.waitForStart("voice-80.0")
            await gate.open("voice-80.0")
            try await EditorBackgroundWorkFixture.waitUntil { controller.voiceStatus == .idle }
            let current = await controller.renderComposition(controller.project, mode: .preview, speechRanges: nil)
            let currentURLs = try await EditorBackgroundWorkFixture.audioSources(in: current.composition)

            await gate.open("voice-20.0")
            try await gate.waitForFinish("voice-20.0")
            try await Task.sleep(for: .milliseconds(30))
            #expect(controller.voiceStatus == .idle)
            let late = await controller.renderComposition(controller.project, mode: .preview, speechRanges: nil)
            #expect(try await EditorBackgroundWorkFixture.audioSources(in: late.composition) == currentURLs)
        }
    }

    @Test(
        "disabling voice or closing cancels pending processing without a late preview rebuild",
        arguments: [false, true])
    func cancelledVoiceCannotRebuild(closing: Bool) async throws {
        try await EditorBackgroundWorkFixture.run { fixture in
            let video = try await fixture.video()
            let gate = fixture.gate()
            let controller = fixture.editor(
                project: fixture.voiceProject(video), render: gate.voiceRender(failing: [20: .renderFailed]))
            try await gate.waitForStart("voice-20.0")
            let expectedStatus: VoiceEnhanceStatus
            if closing {
                expectedStatus = controller.voiceStatus
                await controller.shutdown()
            } else {
                expectedStatus = .idle
                controller.updateVoiceSettings(VoiceEnhanceSettings(enabled: false))
                try await EditorBackgroundWorkFixture.waitUntil { controller.voiceStatus == .idle }
            }
            await gate.open("voice-20.0")
            try await gate.waitForFinish("voice-20.0")
            try await Task.sleep(for: .milliseconds(30))
            #expect(controller.voiceStatus == expectedStatus)
            if closing {
                #expect(controller.player.currentItem == nil)
                #expect(controller.previewState == .empty)
            } else {
                let result = await controller.renderComposition(controller.project, mode: .preview, speechRanges: nil)
                #expect(
                    try await EditorBackgroundWorkFixture.audioSources(in: result.composition).allSatisfy {
                        $0.pathExtension == "mov"
                    })
            }
        }
    }

    @Test("an empty source list remains idle and retains the previously ready audio")
    func emptySourcesPreserveReadyAudio() async throws {
        try await EditorBackgroundWorkFixture.run { fixture in
            let video = try await fixture.video()
            let project = fixture.voiceProject(video)
            let gate = fixture.gate()
            let controller = fixture.editor(project: project, render: gate.voiceRender())
            try await gate.waitForStart("voice-20.0")
            await gate.open("voice-20.0")
            try await EditorBackgroundWorkFixture.waitUntil { controller.voiceStatus == .idle }
            let previous = await controller.renderComposition(project, mode: .preview, speechRanges: nil)
            let previousURLs = try await EditorBackgroundWorkFixture.audioSources(in: previous.composition)
            for clip in project.clips { controller.deleteClip(id: clip.id) }
            controller.updateVoiceSettings(VoiceEnhanceSettings(enabled: true, leveling: 80))
            try await Task.sleep(for: .milliseconds(700))
            #expect(controller.voiceStatus == .idle)
            #expect(await gate.started == ["voice-20.0"])
            let retained = await controller.renderComposition(project, mode: .preview, speechRanges: nil)
            #expect(try await EditorBackgroundWorkFixture.audioSources(in: retained.composition) == previousURLs)
        }
    }
}
