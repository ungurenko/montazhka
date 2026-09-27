import Foundation
import Testing

@testable import MontazhkaKit

/// Настройки экспорта и анимации проходят все места, где проект читается,
/// правится, отменяется и перечитывается: пропуск любого — тихая потеря данных.
@Suite("Project export settings and overlays")
struct ProjectFieldsTests {
    private let agentPreferences = ExportPreferences(normalizeLoudness: false, burnSubtitles: true)

    private func overlay(sourceID: UUID = UUID()) -> ProjectOverlay {
        ProjectOverlay(
            id: UUID(), media: MediaReference(path: "/tmp/overlay.mov"),
            anchor: OverlayAnchor(sourceID: sourceID, sourceTime: 4.2, wordText: "монтаж"),
            align: .payoff, payoffAt: 0.8, duration: 2.5, position: .topRight, scale: 0.4)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-fields-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("a project saved before these fields opens with loudness on and no subtitles or overlays")
    func oldProjectGetsDefaults() throws {
        let json = #"{"id":"\#(UUID().uuidString)","schemaVersion":2,"name":"Старый","clips":[]}"#
        let project = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
        #expect(project.export.normalizeLoudness)
        #expect(!project.export.burnSubtitles)
        #expect(project.overlays.isEmpty)

        let partial = try JSONDecoder().decode(ExportPreferences.self, from: Data(#"{"burnSubtitles":true}"#.utf8))
        #expect(partial.normalizeLoudness && partial.burnSubtitles)
    }

    @Test("export settings and overlays survive saving and loading")
    func fieldsRoundTrip() throws {
        let clip = Clip(sourcePath: "/tmp/a.mov", start: 0, end: 10)
        var project = Project(name: "С анимацией", clips: [clip])
        project.export = agentPreferences
        project.overlays = [overlay(sourceID: clip.source.id)]

        let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        #expect(decoded.export == project.export)
        #expect(decoded.overlays == project.overlays)
    }

    @Test("editor applies export and overlay edits and undoes them one by one")
    func editorUndoesFields() {
        let added = overlay()
        var editor = ProjectEditor(project: Project(name: "Правки"))
        editor.apply(.updateExport(agentPreferences))
        editor.apply(.updateOverlays([added]))
        #expect(editor.project.export == agentPreferences)
        #expect(editor.project.overlays == [added])

        editor.undo()
        #expect(editor.project.overlays.isEmpty)
        #expect(editor.project.export == agentPreferences)
        editor.undo()
        #expect(editor.project.export == ExportPreferences())
    }

    @Test("agent undo brings back export settings and overlays")
    func agentUndoRestoresFields() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = AgentService(baseDirectory: root)
        let clip = Clip(sourcePath: "/tmp/a.mov", start: 0, end: 10)
        var project = Project(name: "Агент", clips: [clip])
        try await service.store.save(project)
        _ = try await service.revisions.push(project)

        project.export = agentPreferences
        project.overlays = [overlay(sourceID: clip.source.id)]
        try await service.store.save(project)

        let response = await service.applyEdits(projectID: project.id, operations: [AgentEditOperation(op: "undo")])
        #expect(response.ok)
        let restored = try await service.store.load(id: project.id)
        #expect(restored.export == ExportPreferences())
        #expect(restored.overlays.isEmpty)
    }

    @MainActor
    @Test("the window picks up the agent's export settings and overlays; removing one is undoable")
    func windowReloadKeepsAgentFields() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(baseDirectory: root)
        let project = Project(name: "Окно")
        try await store.save(project)
        let controller = EditorController(
            project: project, store: store, openRouterKeyStore: EmptyOpenRouterKeyStore())

        var agentVersion = project
        agentVersion.export = agentPreferences
        agentVersion.overlays = [overlay()]
        try await ProjectStore(baseDirectory: root).save(agentVersion)
        await controller.reloadChangedProject(lostLocalEdit: false)
        #expect(controller.project.export == agentPreferences)
        #expect(controller.project.overlays == agentVersion.overlays)

        controller.removeOverlay(id: agentVersion.overlays[0].id)
        #expect(controller.project.overlays.isEmpty)
        controller.undo()
        #expect(controller.project.overlays == agentVersion.overlays)
        controller.undo()
        #expect(controller.project.export == ExportPreferences())
        #expect(controller.project.overlays.isEmpty)
        await controller.shutdown()
    }
}
