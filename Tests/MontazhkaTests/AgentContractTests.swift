import Foundation
import Testing

@testable import MontazhkaKit

@Suite("Agent headless contract")
struct AgentContractTests {
    @Test("MCP exposes the approved compact tool set")
    func compactToolCatalog() throws {
        let tools = AgentToolCatalog.definitions

        #expect(
            tools.map(\.name) == [
                "montazhka_doctor",
                "montazhka_get_projects",
                "montazhka_edit_video",
                "montazhka_make_shorts",
                "montazhka_edit_project",
                "montazhka_get_job",
                "montazhka_inspect",
                "montazhka_export",
            ])
        #expect(AgentToolCatalog.estimatedTokenCount <= 3_000)
        let editVideo = try #require(tools.first { $0.name == "montazhka_edit_video" })
        let editProject = try #require(tools.first { $0.name == "montazhka_edit_project" })
        #expect(editVideo.inputSchema["required"] == .array([.string("sourcePaths")]))
        #expect(editProject.inputSchema["required"] == .array([.string("projectId")]))
        #expect(editVideo.isDestructive)
        #expect(editProject.isDestructive)
    }

    @Test("Agent runs survive a new store instance")
    func runPersistence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-agent-run-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = AgentRunStore(baseDirectory: root)
        let created = try await first.create(kind: .editVideo, sourcePaths: ["/tmp/input.mov"])
        try await first.update(id: created.id) { run in
            run.status = .completed
            run.summary = "Черновик готов"
        }

        let second = AgentRunStore(baseDirectory: root)
        let loaded = try await second.load(id: created.id)
        #expect(loaded.status == .completed)
        #expect(loaded.summary == "Черновик готов")
        #expect(loaded.sourcePaths == ["/tmp/input.mov"])
    }

    @Test("External source ranges are applied exactly and idempotently")
    func exactSourceRanges() {
        let source = "/tmp/input.mov"
        let clips = [Clip(sourcePath: source, start: 0, end: 10)]
        let once = TimelineOps.removingSourceRanges(
            clips: clips,
            sourcePath: source,
            ranges: [(start: 2, end: 3), (start: 6, end: 8)])
        let twice = TimelineOps.removingSourceRanges(
            clips: once,
            sourcePath: source,
            ranges: [(start: 2, end: 3), (start: 6, end: 8)])

        #expect(once.map { [$0.start, $0.end] } == [[0, 2], [3, 6], [8, 10]])
        #expect(twice.map { [$0.start, $0.end] } == [[0, 2], [3, 6], [8, 10]])
    }

    @Test("CLI envelopes keep one stable v1 shape")
    func cliEnvelope() throws {
        let response = AgentResponse.success(command: "doctor", data: ["ready": true])
        let encoded = try JSONEncoder().encode(response)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(object["apiVersion"] as? String == "1")
        #expect(object["ok"] as? Bool == true)
        #expect(object["command"] as? String == "doctor")
        #expect(object["data"] != nil)
    }

    @Test("Partial edit requests keep safe defaults")
    func partialEditRequest() throws {
        let request = try JSONDecoder().decode(
            AgentEditRequest.self,
            from: Data(#"{"sourcePaths":["/tmp/input.mov"],"aiMode":"built-in"}"#.utf8))

        #expect(request.profile == .cleanSpeech)
        #expect(request.removePauses)
        #expect(request.enhanceVoice)
        #expect(request.aiMode == .builtIn)
        #expect(!request.confirmModelDownload)
    }

    @Test("Background editing keeps one run identity")
    func backgroundRunIdentity() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-agent-identity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let video = root.appendingPathComponent("input.mov")
        try await TestVideoFactory.make(segments: [(duration: 1, loud: true)], to: video)
        let runs = AgentRunStore(baseDirectory: root.appendingPathComponent("AgentRuns"))
        let outer = try await runs.create(kind: .editVideo, sourcePaths: [video.path])

        let response = await AgentService(baseDirectory: root).edit(
            AgentEditRequest(
                sourcePaths: [video.path], removePauses: false, enhanceVoice: false),
            runMode: .existing(outer.id))

        #expect(response.ok)
        #expect(response.data?["jobId"] == .string(outer.id.uuidString))
        #expect(try await runs.load(id: outer.id).status == .completed)
        let runDirectories = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("AgentRuns"),
            includingPropertiesForKeys: nil)
        #expect(runDirectories.count == 1)
    }

    @Test("Resource pages preserve UTF-8 characters")
    func utf8ResourcePage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-agent-resource-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runs = AgentRunStore(baseDirectory: root.appendingPathComponent("AgentRuns"))
        let run = try await runs.create(kind: .makeShorts, sourcePaths: [])
        let artifact = try await runs.artifactDirectory(id: run.id).appendingPathComponent("transcript.json")
        try Data("Привет".utf8).write(to: artifact)
        try await runs.update(id: run.id) { $0.artifacts["transcript"] = artifact.path }

        let page = try await AgentService(baseDirectory: root).resource(
            uri: "montazhka://runs/\(run.id.uuidString)/transcript?limit=1")
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(page.utf8)) as? [String: Any])
        let content = try #require(object["content"] as? String)
        #expect(content == "П")
        #expect(!content.contains("�"))
        #expect(object["nextUri"] as? String != nil)
    }

    @Test("Existing compatible model is reused in place")
    func existingModelIsReused() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-agent-model-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("Montazhka/parakeet-tdt-0.6b-v3", isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        for name in [
            "Encoder.mlmodelc", "Decoder.mlmodelc", "Preprocessor.mlmodelc",
            "JointDecisionv3.mlmodelc", "config.json",
        ] {
            let url = model.appendingPathComponent(name)
            if name.hasSuffix(".mlmodelc") {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try Data("{}".utf8).write(to: url)
            }
        }

        #expect(AgentModelLocator.findCompatibleModel(in: root) == model)
    }
}
