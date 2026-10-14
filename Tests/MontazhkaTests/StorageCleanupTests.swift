import Foundation
import Testing

@testable import MontazhkaKit

/// Уборка удаляет файлы навсегда: каждое правило проверено и на «удалить», и на «оставить».
@Suite("Storage cleanup")
struct StorageCleanupTests {
    private let now = Date()
    private var old: Date { now.addingTimeInterval(-15 * 24 * 3600) }

    private func base() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-cleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func file(_ url: URL, _ text: String = "данные", modified: Date? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        return url
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func save(_ project: Project, in base: URL) async throws {
        try await ProjectStore(baseDirectory: base).save(project)
    }

    @Test("an overlay copy no project or revision names is removed; named and fresh copies stay")
    func overlays() async throws {
        let base = try base()
        defer { try? FileManager.default.removeItem(at: base) }
        let overlays = base.appendingPathComponent("Overlays")
        let orphan = try file(overlays.appendingPathComponent("\(UUID().uuidString).mov"), modified: old)
        let fresh = try file(overlays.appendingPathComponent("\(UUID().uuidString).mov"))
        let used = try file(overlays.appendingPathComponent("\(UUID().uuidString).mov"), modified: old)
        let inRevision = try file(overlays.appendingPathComponent("\(UUID().uuidString).mov"), modified: old)
        let project = Project(name: "Живой", clips: [])
        try await save(project, in: base)
        try file(base.appendingPathComponent("Projects/\(project.id.uuidString).json"), "{\"path\":\"\(used.path)\"}")
        try file(
            base.appendingPathComponent("AgentRevisions/\(project.id.uuidString)/1.json"), inRevision.lastPathComponent)

        let summary = StorageCleanup.run(base: base, now: now)

        #expect(!exists(orphan))
        #expect(exists(fresh), "моложе суток — может быть, правка агента ещё идёт")
        #expect(exists(used))
        #expect(exists(inRevision), "к ревизии можно вернуться отменой")
        #expect(summary.files == 1)
    }

    @Test("a voice file of a source that is in no project is removed; live and held ones stay")
    func voices() async throws {
        let base = try base()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = try file(base.appendingPathComponent("talk.mov"))
        let gone = try file(base.appendingPathComponent("gone.mov"))
        let voices = base.appendingPathComponent("EnhancedAudio")
        // Путь — как его видит склейка, по нему голос и кэшируется (/var раскрывается в /private/var).
        let clip = Clip(sourcePath: source.path, start: 0, end: 1)
        let live = try file(
            voices.appendingPathComponent("\(VoiceEnhanceStore.sourceHash(for: clip.sourcePath))-a.caf"), modified: old)
        let goneHash = VoiceEnhanceStore.sourceHash(for: gone.path)
        let orphan = try file(voices.appendingPathComponent("\(goneHash)-a.caf"), modified: old)
        let held = try file(voices.appendingPathComponent("\(goneHash)-b.caf"), modified: old)
        try await save(Project(name: "Голос", clips: [clip]), in: base)
        let lease = CacheFileLease(url: held)

        StorageCleanup.run(base: base, now: now)

        #expect(exists(live))
        #expect(!exists(orphan))
        #expect(exists(held), "его сейчас читает экспорт")
        withExtendedLifetime(lease) {}
    }

    @Test("a source on a disconnected drive leaves every voice file alone")
    func disconnectedDriveKeepsVoices() async throws {
        let base = try base()
        defer { try? FileManager.default.removeItem(at: base) }
        let offline = Clip(sourcePath: "/Volumes/Нет такого диска/talk.mov", start: 0, end: 1)
        try await save(Project(name: "На внешнем диске", clips: [offline]), in: base)
        let voice = try file(base.appendingPathComponent("EnhancedAudio/abc-a.caf"), modified: old)

        StorageCleanup.run(base: base, now: now)

        #expect(exists(voice), "диск подключат — голос снова пригодится")
    }

    @Test("an unreadable project leaves every voice file alone")
    func unreadableProjectKeepsVoices() throws {
        let base = try base()
        defer { try? FileManager.default.removeItem(at: base) }
        try file(base.appendingPathComponent("Projects/\(UUID().uuidString).json"), "{не json")
        let voice = try file(base.appendingPathComponent("EnhancedAudio/abc-a.caf"), modified: old)

        StorageCleanup.run(base: base, now: now)

        #expect(exists(voice), "чьи это исходники, неизвестно")
    }

    @Test("a finished job older than two weeks is removed; running, waiting-fresh and recent jobs stay")
    func runs() async throws {
        let base = try base()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = AgentRunStore(baseDirectory: base.appendingPathComponent("AgentRuns"))
        func job(_ status: AgentRunStatus, updated: Date) async throws -> URL {
            let run = try await store.create(kind: .export, sourcePaths: [])
            let url = try await store.artifactDirectory(id: run.id).appendingPathComponent("run.json")
            var stored = try await store.load(id: run.id)
            stored.status = status
            stored.updatedAt = updated
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(stored).write(to: url)
            return url.deletingLastPathComponent()
        }
        let finished = try await job(.completed, updated: old)
        let failed = try await job(.failed, updated: old)
        let recent = try await job(.completed, updated: now)
        let running = try await job(.running, updated: old)
        let held = try await job(.completed, updated: old)
        let lock = try FileLock(lockFile: held.appendingPathComponent("worker.lock"), wait: false)

        StorageCleanup.run(base: base, now: now)

        #expect(!exists(finished))
        #expect(!exists(failed))
        #expect(exists(recent))
        #expect(exists(running), "незаконченную задачу сначала сверяет reconcileAll")
        #expect(exists(held), "её исполнитель ещё жив")
        withExtendedLifetime(lock) {}
    }

    @Test("revisions: a deleted project loses its history, a live one keeps the newest snapshots")
    func revisions() async throws {
        let base = try base()
        defer { try? FileManager.default.removeItem(at: base) }
        let project = Project(name: "Живой", clips: [])
        try await save(project, in: base)
        let store = AgentRevisionStore(baseDirectory: base.appendingPathComponent("AgentRevisions"))
        for _ in 0..<(StorageCleanup.revisionsKept + 5) { _ = try await store.push(project) }
        let deleted = UUID()
        let orphan = try file(base.appendingPathComponent("AgentRevisions/\(deleted.uuidString)/1.json"))
        try FileManager.default.setAttributes(
            [.modificationDate: old], ofItemAtPath: orphan.deletingLastPathComponent().path)
        let note = try file(base.appendingPathComponent("AgentNotes/\(deleted.uuidString).md"), modified: old)
        let liveNote = try file(base.appendingPathComponent("AgentNotes/\(project.id.uuidString).md"), modified: old)

        StorageCleanup.run(base: base, now: now)

        #expect(!exists(orphan.deletingLastPathComponent()))
        #expect(!exists(note))
        #expect(exists(liveNote))
        let left = try FileManager.default.contentsOfDirectory(
            atPath: base.appendingPathComponent("AgentRevisions/\(project.id.uuidString)").path)
        #expect(left.count == StorageCleanup.revisionsKept)
        #expect(await store.revision(of: project.id) == StorageCleanup.revisionsKept + 5, "номер ревизии не падает")
        #expect(try await store.push(project) == StorageCleanup.revisionsKept + 6)
        let restored = try await store.snapshot(projectID: project.id, steps: 1)
        #expect(restored.id == project.id)
    }

    @Test("cleanup runs at most once a day")
    func onceADay() throws {
        let base = try base()
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(StorageCleanup.runIfDue(base: base, now: now) != nil)
        let orphan = try file(base.appendingPathComponent("Overlays/\(UUID().uuidString).mov"), modified: old)

        #expect(StorageCleanup.runIfDue(base: base, now: now.addingTimeInterval(3600)) == nil)
        #expect(exists(orphan))
        #expect(StorageCleanup.runIfDue(base: base, now: now.addingTimeInterval(StorageCleanup.interval + 1)) != nil)
        #expect(!exists(orphan))
    }

    @Test("a slot queue reports waiting once and hands out the slot when one frees up")
    func slotQueueReportsWaiting() async throws {
        let base = try base()
        defer { try? FileManager.default.removeItem(at: base) }
        var first: FileLock? = try await FileLock.acquireSlot(in: base, count: 2)
        let second = try await FileLock.acquireSlot(in: base, count: 2)
        let waits = WaitCounter()
        let third = Task { _ = try await FileLock.acquireSlot(in: base, count: 2) { await waits.add() } }
        for _ in 0..<100 where await waits.calls == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await waits.calls == 1)

        first = nil
        try await third.value
        #expect(await waits.calls == 1, "о ожидании сообщается один раз")
        withExtendedLifetime((first, second)) {}
    }
}

private actor WaitCounter {
    private(set) var calls = 0
    func add() { calls += 1 }
}
