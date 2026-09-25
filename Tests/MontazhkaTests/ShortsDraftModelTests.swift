import Foundation
import Testing

@testable import MontazhkaKit

@Suite("Shorts draft model")
struct ShortsDraftModelTests {
    private func sampleShorts(sourceID: UUID) -> ShortsPresentation {
        ShortsPresentation(
            title: "Как я монтирую", reason: "сильный хук",
            layout: .auto, resolvedLayout: .split,
            hook: ShortsHook(text: "Монтаж за минуту"),
            subtitles: ShortsDraftSubtitles(appearance: ShortsSubtitlePreset.accent.appearance, highlight: true),
            zooms: [ShortsZoom(sourceID: sourceID, sourceStart: 3, sourceEnd: 6, scale: 1.08)],
            exportPath: "/tmp/short.mp4")
    }

    @Test("a v1 project on disk opens as a plain project")
    func legacyProjectHasNoShorts() throws {
        let json = """
            {"id":"\(UUID().uuidString)","schemaVersion":1,"name":"Старый","clips":[]}
            """
        let project = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
        #expect(project.shorts == nil)
        #expect(project.schemaVersion == Project.currentSchemaVersion)
        #expect(Project.currentSchemaVersion == 2)
    }

    @Test("a shorts draft survives saving and loading")
    func shortsRoundTrip() throws {
        let clip = Clip(sourcePath: "/tmp/a.mov", start: 0, end: 10)
        var project = Project(name: "Шортс", clips: [clip])
        project.shorts = sampleShorts(sourceID: clip.source.id)
        project.music.ducking = true

        let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        #expect(decoded.shorts == project.shorts)
        #expect(decoded.music.ducking)
        #expect(decoded.shorts?.hook?.duration == ShortsHook.defaultDuration)
    }

    @Test("music without the ducking key stays undimmed")
    func musicDuckingDefaultsOff() throws {
        let music = try JSONDecoder().decode(MusicSettings.self, from: Data(#"{"enabled":true,"volume":20}"#.utf8))
        #expect(!music.ducking)
    }

    @Test("editor applies a shorts update and undoes it")
    func editorUpdatesShorts() {
        var editor = ProjectEditor(project: Project(name: "Шортс"))
        editor.apply(.updateShorts(sampleShorts(sourceID: UUID())))
        #expect(editor.project.shorts?.title == "Как я монтирую")
        editor.undo()
        #expect(editor.project.shorts == nil)
    }

    @Test("agent undo brings back shorts styling and music, not only clips")
    func agentUndoRestoresShorts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = AgentService(baseDirectory: root)
        let clip = Clip(sourcePath: "/tmp/a.mov", start: 0, end: 10)
        var project = Project(name: "Шортс", clips: [clip])
        project.shorts = sampleShorts(sourceID: clip.source.id)
        try await service.store.save(project)
        _ = try await service.revisions.push(project)

        project.shorts?.hook = ShortsHook(text: "Другой хук")
        project.music.trackID = "Энергичная 1"
        try await service.store.save(project)

        let response = await service.applyEdits(projectID: project.id, operations: [AgentEditOperation(op: "undo")])
        #expect(response.ok)
        let restored = try await service.store.load(id: project.id)
        #expect(restored.shorts?.hook?.text == "Монтаж за минуту")
        #expect(restored.music.trackID == nil)
    }
}
