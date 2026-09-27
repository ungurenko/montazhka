import Foundation
import Testing

@testable import MontazhkaKit

/// Заметки проекта через агентские инструменты: inspect, apply_edits, undo и копия проекта.
@Suite("Agent project notes through the tools")
struct AgentNotesTests {
    private struct Fixture {
        let root: URL
        let service: AgentService
        let project: Project
    }

    /// Проект «Заметки». `realVideo == false` — исходник не существует (медиа офлайн).
    private func fixture(realVideo: Bool) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-notes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let video = root.appendingPathComponent("talk.mov")
        if realVideo { try await TestVideoFactory.make(segments: [(duration: 2, loud: true)], to: video) }
        let service = AgentService(baseDirectory: root)
        let project = Project(name: "Заметки", clips: [Clip(sourcePath: video.path, start: 0, end: 2)])
        try await service.store.save(project)
        return Fixture(root: root, service: service, project: project)
    }

    private func note(_ text: String?, op: String = "note") -> AgentEditOperation {
        var operation = AgentEditOperation(op: op)
        operation.text = text
        return operation
    }

    private func split(at time: Double) -> AgentEditOperation {
        var operation = AgentEditOperation(op: "split")
        operation.at = time
        return operation
    }

    private func notesText(_ fixture: Fixture) async -> String? {
        guard case .string(let text)? = await fixture.service.inspect(projectID: fixture.project.id).data?["notes"]
        else { return nil }
        return text
    }

    @Test("a note appended through apply_edits shows up in inspect")
    func appendedNoteInInspect() async throws {
        let fixture = try await fixture(realVideo: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        #expect(await fixture.service.inspect(projectID: fixture.project.id).data?["notes"] == .null)

        let response = await fixture.service.applyEdits(
            projectID: fixture.project.id, operations: [note("Бриф: убрать паузы")])

        #expect(response.ok, "\(String(describing: response.error))")
        #expect(await notesText(fixture)?.contains("Бриф: убрать паузы") == true)
    }

    @Test("a notes-only batch saves nothing else and works while the media is offline")
    func notesOnlyBatchLeavesProjectAlone() async throws {
        let fixture = try await fixture(realVideo: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = await fixture.service.store
        let projectFile = store.projectsDir.appendingPathComponent("\(fixture.project.id.uuidString).json")
        let bytesBefore = try Data(contentsOf: projectFile)
        let stampBefore = store.diskStamp(of: fixture.project.id)

        let response = await fixture.service.applyEdits(
            projectID: fixture.project.id, operations: [note("первая"), note("вторая")])

        #expect(response.ok, "\(String(describing: response.error))")
        #expect(response.data?["notesSaved"] == .bool(true))
        #expect(response.data?["revision"] == .number(0))
        #expect(response.data?["clipCount"] == .number(1))
        #expect(try Data(contentsOf: projectFile) == bytesBefore)
        #expect(store.diskStamp(of: fixture.project.id) == stampBefore)
        #expect(await fixture.service.revisions.revision(of: fixture.project.id) == 0)
        let text = try #require(await notesText(fixture))
        #expect(text.contains("первая") && text.contains("вторая"))
    }

    @Test("a mixed batch edits the timeline and writes the note; undo keeps the note")
    func mixedBatchAndUndo() async throws {
        let fixture = try await fixture(realVideo: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let edited = await fixture.service.applyEdits(
            projectID: fixture.project.id, operations: [split(at: 1), note("разрезал на 1 с")])

        #expect(edited.ok, "\(String(describing: edited.error))")
        #expect(edited.data?["clipCount"] == .number(2))
        #expect(edited.data?["notesSaved"] == .bool(true))
        #expect(await notesText(fixture)?.contains("разрезал на 1 с") == true)

        let undone = await fixture.service.applyEdits(
            projectID: fixture.project.id, operations: [AgentEditOperation(op: "undo")])

        #expect(undone.ok, "\(String(describing: undone.error))")
        #expect(undone.data?["clipCount"] == .number(1))
        #expect(await notesText(fixture)?.contains("разрезал на 1 с") == true)
    }

    @Test("a note that cannot be written after a saved edit is a warning, not a failure")
    func noteFailureAfterSaveIsWarning() async throws {
        let fixture = try await fixture(realVideo: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let tooLong = String(repeating: "а", count: AgentNotesStore.maxCharacters + 1)

        let response = await fixture.service.applyEdits(
            projectID: fixture.project.id, operations: [split(at: 1), note(tooLong)])

        #expect(response.ok, "\(String(describing: response.error))")
        #expect(response.data?["clipCount"] == .number(2))
        #expect(response.data?["notesSaved"] == .bool(false))
        guard case .array(let warnings)? = response.data?["warnings"] else {
            Issue.record("нет warnings: \(String(describing: response.data))")
            return
        }
        #expect(
            warnings.contains {
                if case .string(let text) = $0 { text.hasPrefix("Заметка не записана: ") } else { false }
            })
    }

    @Test("several note ops in one batch are saved all together or not at all")
    func noteBatchIsAllOrNothing() async throws {
        let fixture = try await fixture(realVideo: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let id = fixture.project.id
        let tooLong = String(repeating: "а", count: AgentNotesStore.maxCharacters + 1)

        let refused = await fixture.service.applyEdits(projectID: id, operations: [note("первая"), note(tooLong)])

        #expect(!refused.ok)
        #expect(await fixture.service.inspect(projectID: id).data?["notes"] == .null, "первая заметка не записана")

        // Длина проверяется по итогу пачки: длинный промежуточный текст, сжатый setNotes, проходит.
        let long = String(repeating: "б", count: AgentNotesStore.maxCharacters - 5)
        #expect(await fixture.service.applyEdits(projectID: id, operations: [note(long, op: "setNotes")]).ok)
        let compressed = await fixture.service.applyEdits(
            projectID: id, operations: [note("ещё решение"), note("сжато", op: "setNotes"), note("итог")])
        #expect(compressed.ok, "\(String(describing: compressed.error))")
        let text = try #require(await notesText(fixture))
        #expect(text.hasPrefix("сжато\n## "))
        #expect(text.hasSuffix("\nитог"))
        #expect(!text.contains("ещё решение"))
    }

    @Test("a mixed batch whose notes do not fit saves the edit, no note, and says notesSaved false")
    func mixedBatchNotesSavedIsTruthful() async throws {
        let fixture = try await fixture(realVideo: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let tooLong = String(repeating: "а", count: AgentNotesStore.maxCharacters + 1)

        let response = await fixture.service.applyEdits(
            projectID: fixture.project.id, operations: [split(at: 1), note("разрезал"), note(tooLong)])

        #expect(response.ok, "\(String(describing: response.error))")
        #expect(response.data?["clipCount"] == .number(2))
        #expect(response.data?["notesSaved"] == .bool(false))
        #expect(await notesText(fixture) == nil, "ни одна заметка пачки не записана")
    }

    @Test("setNotes replaces the notes, an empty text clears them, a note needs text")
    func setNotesReplacesAndClears() async throws {
        let fixture = try await fixture(realVideo: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let id = fixture.project.id

        _ = await fixture.service.applyEdits(projectID: id, operations: [note("старое")])
        let replaced = await fixture.service.applyEdits(projectID: id, operations: [note("сжато", op: "setNotes")])
        #expect(replaced.ok, "\(String(describing: replaced.error))")
        #expect(await notesText(fixture) == "сжато")

        let cleared = await fixture.service.applyEdits(projectID: id, operations: [note("", op: "setNotes")])
        #expect(cleared.ok, "\(String(describing: cleared.error))")
        #expect(await fixture.service.inspect(projectID: id).data?["notes"] == .null)

        #expect(!(await fixture.service.applyEdits(projectID: id, operations: [note("  ")])).ok)
        #expect(!(await fixture.service.applyEdits(projectID: id, operations: [note(nil, op: "setNotes")])).ok)
        #expect(await fixture.service.inspect(projectID: id).data?["notes"] == .null)
    }

    @Test("a copy of the project made by edit_project gets a copy of the notes")
    func projectCopyGetsNotes() async throws {
        let fixture = try await fixture(realVideo: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = await fixture.service.applyEdits(projectID: fixture.project.id, operations: [note("решение: без музыки")])

        let response = await fixture.service.edit(
            AgentEditRequest(
                sourcePaths: [], projectID: fixture.project.id, removePauses: false, enhanceVoice: false))

        guard case .string(let id)? = response.data?["projectId"], let copyID = UUID(uuidString: id) else {
            Issue.record("копия не создана: \(String(describing: response.error))")
            return
        }
        let copied = try #require(await fixture.service.notes.read(copyID))
        #expect(copied.contains("Копия проекта «Заметки» (\(fixture.project.id.uuidString))"))
        #expect(copied.contains("решение: без музыки"))
    }
}
