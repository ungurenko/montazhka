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
                "montazhka_transcript",
                "montazhka_frames",
                "montazhka_audio",
                "montazhka_apply_edits",
                "montazhka_check",
            ])
        #expect(AgentToolCatalog.estimatedTokenCount <= 3_000)
        let editVideo = try #require(tools.first { $0.name == "montazhka_edit_video" })
        let editProject = try #require(tools.first { $0.name == "montazhka_edit_project" })
        #expect(editVideo.inputSchema["required"] == .array([.string("sourcePaths")]))
        #expect(editProject.inputSchema["required"] == .array([.string("projectId")]))
        #expect(editVideo.isDestructive)
        #expect(editProject.isDestructive)
    }

    @Test("transcript takes a project or any file with phrases and retakes; notes ops are listed")
    func transcriptAndNotesContract() throws {
        let tools = AgentToolCatalog.definitions
        let transcript = try #require(tools.first { $0.name == "montazhka_transcript" })
        #expect(transcript.inputSchema["required"] == .array([]))
        guard case .object(let properties)? = transcript.inputSchema["properties"] else {
            Issue.record("у transcript нет properties")
            return
        }
        for key in ["projectId", "filePath", "phrases", "retakes"] {
            #expect(properties[key] != nil, "transcript без поля \(key)")
        }
        let edits = try #require(tools.first { $0.name == "montazhka_apply_edits" })
        let encoded = String(decoding: try JSONEncoder().encode(edits.inputSchema), as: UTF8.self)
        #expect(encoded.contains("\"setNotes\"") && encoded.contains("\"note\""))

        let guide = AgentDocumentation.guide
        for phrase in [
            "## Заметки проекта", "## Дубли", #"{"op":"note","text":"#, "setNotes", "retakes=true", "filePath",
        ] {
            #expect(guide.contains(phrase), "в гайде нет «\(phrase)»")
        }
        #expect(AgentDocumentation.skill.contains("notes"))
        #expect(AgentDocumentation.skill.contains("retakes"))
    }

    @Test("check is read-only; overlays and export options are in the schemas; guide explains them")
    func checkOverlaysAndExportOptionsContract() throws {
        let tools = AgentToolCatalog.definitions
        let check = try #require(tools.first { $0.name == "montazhka_check" })
        #expect(check.isReadOnly && !check.isDestructive)
        #expect(check.inputSchema["required"] == .array([.string("projectId")]))
        let edits = try #require(tools.first { $0.name == "montazhka_apply_edits" })
        let encodedEdits = String(decoding: try JSONEncoder().encode(edits.inputSchema), as: UTF8.self)
        for op in ["addOverlay", "removeOverlay", "clearOverlays", "payoffAt"] {
            #expect(encodedEdits.contains("\"\(op)\""), "в apply_edits нет \(op)")
        }
        let export = try #require(tools.first { $0.name == "montazhka_export" })
        guard case .object(let exportProperties)? = export.inputSchema["properties"] else {
            Issue.record("у export нет properties")
            return
        }
        #expect(exportProperties["normalizeLoudness"] != nil && exportProperties["burnSubtitles"] != nil)

        let guide = AgentDocumentation.guide
        for phrase in [
            "## Критик перед сдачей", "## Анимации поверх видео", "montazhka://critic",
            "montazhka_check projectId filePath",
            "−14 LUFS", "normalizeLoudness=false", "burnSubtitles=true", "--format mov", "payoffAt", "frameSize",
        ] {
            #expect(guide.contains(phrase), "в гайде нет «\(phrase)»")
        }
        #expect(AgentDocumentation.skill.contains("montazhka://critic"))
    }

    @Test("the critic prompt is served verbatim as a resource and by the CLI")
    func criticPrompt() async throws {
        let expected = AgentDocumentation.critic
        #expect(AgentDocumentation.resourceText(uri: "montazhka://critic") == expected)
        #expect(AgentDocumentation.resourceText(uri: "montazhka://guide") == AgentDocumentation.guide)
        #expect(AgentDocumentation.resources.map(\.uri) == ["montazhka://guide", "montazhka://critic"])
        let cli = await AgentCommand.execute(["critic-prompt"])
        #expect(cli.ok)
        #expect(cli.data?["text"] == .string(expected))
    }

    @Test("MCP export arguments and defaults reach the worker unchanged")
    func exportOptionsFromMCP() throws {
        let id = UUID()
        let chosen = AgentCommand.mcpExportRequest(
            projectID: id,
            arguments: [
                "outputPath": "/tmp/export.mp4", "quality": "high", "final": true,
                "confirmFinal": true, "overwrite": true, "normalizeLoudness": false, "burnSubtitles": true,
            ])
        guard
            case .export(
                let project, let output, let quality, let final, let confirmFinal, let overwrite,
                let loudness, let burn
            ) = chosen
        else {
            Issue.record("не экспорт: \(chosen)")
            return
        }
        #expect(project == id && output == "/tmp/export.mp4" && quality == "high")
        #expect(final && confirmFinal && overwrite)
        #expect(loudness == false && burn == true)
        guard
            case .export(
                _, let defaultOutput, let defaultQuality, let defaultFinal, let defaultConfirm,
                let defaultOverwrite, let unset, let unsetBurn) = AgentCommand.mcpExportRequest(
                    projectID: id, arguments: [:])
        else {
            Issue.record("не экспорт")
            return
        }
        #expect(defaultOutput == nil && defaultQuality == "compact")
        #expect(!defaultFinal && !defaultConfirm && !defaultOverwrite)
        #expect(unset == nil && unsetBurn == nil, "без полей — как в настройках проекта")
    }

    @Test("CLI export flags force loudness and burned subtitles either way; no flag keeps the project setting")
    func cliExportFlagsBothWays() throws {
        func flag(_ args: [String]) throws -> Bool? {
            try AgentCommand.exportFlag(on: "--burn-subtitles", off: "--no-burn-subtitles", in: args)
        }
        #expect(try flag(["export", "--burn-subtitles"]) == true)
        #expect(try flag(["export", "--no-burn-subtitles"]) == false)
        #expect(try flag(["export", "--no-normalize-loudness"]) == nil)
        #expect(
            try AgentCommand.exportFlag(
                on: "--normalize-loudness", off: "--no-normalize-loudness", in: ["export", "--normalize-loudness"])
                == true)
    }

    @Test(
        "CLI export refuses contradictory flag pairs before touching any project",
        arguments: [
            ["--normalize-loudness", "--no-normalize-loudness"], ["--burn-subtitles", "--no-burn-subtitles"],
        ])
    func cliContradictoryExportFlags(_ flags: [String]) async {
        let response = await AgentCommand.execute(["export", "--project", UUID().uuidString] + flags)

        #expect(response.error?.code == "INVALID_INPUT", "\(String(describing: response.error))")
        #expect(response.error?.message.contains(flags[0]) == true)
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

    @Test("CLI edit requests accept the MCP spelling projectId")
    func editRequestProjectIDSpellings() throws {
        let id = UUID()
        for key in ["projectID", "projectId"] {
            let request = try JSONDecoder().decode(
                AgentEditRequest.self, from: Data(#"{"\#(key)":"\#(id.uuidString)"}"#.utf8))
            #expect(request.projectID == id)
        }
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
