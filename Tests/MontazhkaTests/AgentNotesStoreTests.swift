import Foundation
import Testing

@testable import MontazhkaKit

@Suite("Agent notes store")
struct AgentNotesStoreTests {
    private func withStore(_ body: (AgentNotesStore, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-notes-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("AgentNotes", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        try await body(AgentNotesStore(baseDirectory: directory), directory)
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int) throws -> Date {
        try #require(
            Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute)))
    }

    /// Проверяет, что вызов бросил ошибку лимита с подсказкой про setNotes.
    private func expectLimitError(_ body: () async throws -> Void) async {
        do {
            try await body()
            Issue.record("Ожидалась ошибка лимита заметок")
        } catch {
            #expect(error is AgentServiceError)
            #expect(error.localizedDescription.contains("setNotes"))
        }
    }

    @Test("append creates the file and adds dated headers")
    func appendAddsHeaders() async throws {
        try await withStore { store, directory in
            let id = UUID()
            try await store.append(id, text: "Бриф: короткий ролик для канала", at: date(27, 14, 5))
            try await store.append(id, text: "Решение: без музыки", at: date(28, 9, 30))

            #expect(
                await store.read(id)
                    == "\n## 2026-09-27 14:05\nБриф: короткий ролик для канала\n## 2026-09-28 09:30\nРешение: без музыки"
            )
            #expect(
                FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(id.uuidString).md").path))
        }
    }

    @Test("read of a project without notes is nil")
    func readMissing() async throws {
        try await withStore { store, _ in
            #expect(await store.read(UUID()) == nil)
        }
    }

    @Test("replace rewrites the notes, empty text deletes the file")
    func replaceAndClear() async throws {
        try await withStore { store, directory in
            let id = UUID()
            try await store.append(id, text: "старое", at: date(27, 10, 0))
            try await store.replace(id, text: "Сжатые заметки")
            #expect(await store.read(id) == "Сжатые заметки")

            try await store.replace(id, text: "")
            #expect(await store.read(id) == nil)
            #expect(
                !FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(id.uuidString).md").path))
            try await store.replace(UUID(), text: "")
        }
    }

    @Test("copy puts the header above the source notes and keeps existing destination notes")
    func copyWithHeader() async throws {
        try await withStore { store, _ in
            let source = UUID()
            let fresh = UUID()
            let existing = UUID()
            try await store.replace(source, text: "Бриф: ролик про звук")
            try await store.replace(existing, text: "Свои заметки")

            try await store.copy(from: source, to: fresh, header: "Копия проекта «Звук» (\(source.uuidString))")
            try await store.copy(from: source, to: existing, header: "Копия")
            try await store.copy(from: UUID(), to: source, header: "Ничего")

            #expect(await store.read(fresh) == "Копия проекта «Звук» (\(source.uuidString))\nБриф: ролик про звук")
            #expect(await store.read(existing) == "Свои заметки\nКопия\nБриф: ролик про звук")
            #expect(await store.read(source) == "Бриф: ролик про звук")
        }
    }

    @Test("notes longer than the limit are refused with a hint to compress them via setNotes")
    func limitError() async throws {
        try await withStore { store, _ in
            let id = UUID()
            try await store.replace(id, text: String(repeating: "а", count: AgentNotesStore.maxCharacters))
            #expect(await store.read(id)?.count == AgentNotesStore.maxCharacters)

            await expectLimitError { try await store.append(id, text: "ещё", at: date(27, 12, 0)) }
            await expectLimitError {
                try await store.replace(id, text: String(repeating: "б", count: AgentNotesStore.maxCharacters + 1))
            }
            #expect(await store.read(id) == String(repeating: "а", count: AgentNotesStore.maxCharacters))
        }
    }

    @Test("concurrent appends from several tasks keep every note")
    func concurrentAppends() async throws {
        try await withStore { store, _ in
            let id = UUID()
            let when = try date(27, 16, 0)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<20 {
                    group.addTask { try await store.append(id, text: "заметка \(index)", at: when) }
                }
                try await group.waitForAll()
            }
            let notes = try #require(await store.read(id))
            for index in 0..<20 {
                #expect(
                    notes.contains("## 2026-09-27 16:00\nзаметка \(index)\n") || notes.hasSuffix("заметка \(index)"))
            }
            #expect(notes.components(separatedBy: "## 2026-09-27 16:00").count == 21)
        }
    }
}
