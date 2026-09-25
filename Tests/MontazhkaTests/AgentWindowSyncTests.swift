import Foundation
import Testing

@testable import MontazhkaKit

/// Окно и агент работают с одним файлом проекта из разных процессов.
@Suite("Agent and window share a project")
struct AgentWindowSyncTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-sync-\(UUID().uuidString)", isDirectory: true)
    }

    @MainActor
    @Test("window save does not overwrite a project the agent changed")
    func windowKeepsAgentEdit() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let windowStore = ProjectStore(baseDirectory: root)
        let agentStore = ProjectStore(baseDirectory: root)
        var project = Project(name: "общий")
        project.clips = [Clip(sourcePath: "/tmp/a.mov", start: 0, end: 10)]
        try await windowStore.save(project)

        let coordinator = ProjectSaveCoordinator(repository: windowStore)
        coordinator.adoptDiskStamp(for: project.id)
        var externalChanges = 0
        coordinator.onExternalChange = { externalChanges += 1 }

        var agentVersion = project
        agentVersion.clips = [Clip(sourcePath: "/tmp/a.mov", start: 0, end: 4)]
        try await agentStore.save(agentVersion)
        #expect(coordinator.diskChangedElsewhere(for: project.id))

        var windowVersion = project
        windowVersion.name = "правка окна"
        await coordinator.saveNow(windowVersion)
        coordinator.saveBeforeTermination(windowVersion)

        let onDisk = try await agentStore.load(id: project.id)
        #expect(onDisk.clips.map(\.end) == [4])
        #expect(onDisk.name == "общий")
        #expect(externalChanges == 1)
    }

    @MainActor
    @Test("the window's own saves are not mistaken for agent edits")
    func ownSavesAreKnown() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(baseDirectory: root)
        var project = Project(name: "своё")
        try await store.save(project)
        let coordinator = ProjectSaveCoordinator(repository: store)
        coordinator.adoptDiskStamp(for: project.id)

        project.name = "своё 2"
        await coordinator.saveNow(project)
        project.name = "своё 3"
        await coordinator.saveNow(project)

        #expect(!coordinator.diskChangedElsewhere(for: project.id))
        #expect(try await store.load(id: project.id).name == "своё 3")
    }

    @Test("get_job with waitSeconds returns as soon as the stage changes")
    func jobWaitsForStageChange() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = AgentService(baseDirectory: root)
        let run = try await service.runs.create(kind: .transcribe, sourcePaths: [])
        try await service.runs.update(id: run.id) {
            $0.status = .running
            $0.stage = "Расшифровка 1 из 2"
        }
        let runs = await service.runs
        Task {
            try await Task.sleep(for: .milliseconds(700))
            try await runs.update(id: run.id) { $0.stage = "Расшифровка 2 из 2" }
        }

        let started = ContinuousClock.now
        let response = await service.job(id: run.id, waitSeconds: 10)

        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(response.data?["stage"] == .string("Расшифровка 2 из 2"))
    }

    @Test("get_job does not wait for a finished job")
    func jobDoesNotWaitWhenDone() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = AgentService(baseDirectory: root)
        let run = try await service.runs.create(kind: .transcribe, sourcePaths: [])
        try await service.runs.update(id: run.id) { $0.status = .completed }

        let started = ContinuousClock.now
        _ = await service.job(id: run.id, waitSeconds: 10)
        #expect(ContinuousClock.now - started < .seconds(1))
    }

    @Test("inspect pages through long timelines")
    func inspectPages() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = AgentService(baseDirectory: root)
        var project = Project(name: "длинный")
        project.clips = (0..<5).map { Clip(sourcePath: "/tmp/a.mov", start: Double($0), end: Double($0) + 0.5) }
        try await service.store.save(project)

        let page = await service.inspect(projectID: project.id, offset: 2, limit: 2)
        guard case .array(let clips)? = page.data?["clips"] else {
            Issue.record("inspect не вернул список клипов")
            return
        }
        #expect(clips.count == 2)
        #expect(clips.first.flatMap { if case .object(let clip) = $0 { clip["clip"] } else { nil } } == .number(2))
        #expect(page.data?["nextOffset"] == .number(4))

        let last = await service.inspect(projectID: project.id, offset: 4, limit: 2)
        #expect(last.data?["nextOffset"] == .null)
    }

    @Test("a connected agent gets the new skill text on app launch")
    func skillRefresh() throws {
        let home = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let skill = home.appendingPathComponent(".claude/skills/montazhka/SKILL.md")
        try FileManager.default.createDirectory(
            at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("старый скилл".utf8).write(to: skill)

        #expect(AgentIntegrationInstaller.refreshSkillsIfInstalled(home: home) == 0)

        let wrapper = home.appendingPathComponent(".local/bin/montazhka")
        try FileManager.default.createDirectory(
            at: wrapper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: wrapper)

        #expect(AgentIntegrationInstaller.refreshSkillsIfInstalled(home: home) == 1)
        #expect(try String(contentsOf: skill, encoding: .utf8) == AgentDocumentation.skill)
        #expect(AgentIntegrationInstaller.refreshSkillsIfInstalled(home: home) == 0)
    }
}
