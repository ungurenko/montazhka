@preconcurrency import AVFoundation
import Foundation
import Testing

@testable import MontazhkaKit

@Suite("Agent makes shorts drafts")
struct AgentShortsTests {
    private struct Fixture {
        let root: URL
        let service: AgentService
        let project: Project
        let timeline: String
    }

    /// Проект из 12-секундного тестового видео с расшифровкой в кэше:
    /// 16 слов, по одному каждые 0.7 с.
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let video = root.appendingPathComponent("talk.mov")
        try await TestVideoFactory.make(segments: [(duration: 12, loud: true)], to: video)
        let service = AgentService(baseDirectory: root)
        let media = MediaReference(url: video)
        let project = Project(name: "Эфир", clips: [Clip(source: media, start: 0, end: 12)])
        try await service.store.save(project)
        let words = (0..<16).map { index in
            TranscriptWord(
                sourceID: media.id, text: index == 7 ? "главное." : "слово", start: 0.5 + Double(index) * 0.7,
                end: 0.5 + Double(index) * 0.7 + 0.5, confidence: 1)
        }
        let cacheURL = await service.makeTranscriptStore().cacheURL(for: media)
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(TranscriptDocument(words: words)).write(to: cacheURL)
        return Fixture(
            root: root, service: service, project: project, timeline: AgentWordCuts.fingerprint(project.clips))
    }

    private func spec(_ pieces: [ShortsDraftFactory.Piece], zooms: [AgentWordRange]? = []) -> ShortsDraftFactory.Spec {
        ShortsDraftFactory.Spec(
            title: "Главное", hook: "Вот что важно", subtitles: false, pieces: pieces, layout: .fit,
            zooms: zooms, music: nil, mood: "energetic")
    }

    @Test("the agent's word ranges become a saved draft and a vertical MP4")
    func makesDraft() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let request = AgentShortsRequest(
            projectID: fixture.project.id, timeline: fixture.timeline,
            shorts: [spec([ShortsDraftFactory.Piece(from: 2, to: 9), ShortsDraftFactory.Piece(from: 12, to: 14)])],
            quality: "compact")
        let response = await fixture.service.makeShorts(request)
        #expect(response.ok, "\(String(describing: response.error))")
        guard case .array(let shorts)? = response.data?["shorts"], case .object(let first)? = shorts.first,
            case .string(let id)? = first["projectId"], case .string(let output)? = first["output"]
        else {
            Issue.record("нет списка шортсов: \(String(describing: response.data))")
            return
        }
        let draft = try await fixture.service.store.load(id: try #require(UUID(uuidString: id)))
        #expect(draft.shorts?.hook?.text == "Вот что важно")
        #expect(draft.clips.count == 2)
        #expect(draft.music.enabled && draft.music.ducking)
        #expect(draft.voiceEnhance.enabled)
        #expect(draft.shorts?.exportPath == output)
        let track = try #require(
            try await AVURLAsset(url: URL(fileURLWithPath: output)).loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(size.height > size.width)
    }

    @Test("without shorts the tool explains that the agent picks the moments")
    func refusesWithoutShorts() async {
        let response = await AgentService(baseDirectory: FileManager.default.temporaryDirectory)
            .makeShorts(AgentShortsRequest(projectID: UUID(), timeline: "", shorts: []))
        #expect(!response.ok)
        #expect(response.error?.code == "INVALID_REQUEST")
    }

    @Test("a zoom stays on its words after words before it are deleted")
    func zoomSurvivesEdits() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let response = await fixture.service.makeShorts(
            AgentShortsRequest(
                projectID: fixture.project.id, timeline: fixture.timeline,
                shorts: [spec([ShortsDraftFactory.Piece(from: 1, to: 16)], zooms: [AgentWordRange(from: 10, to: 12)])],
                quality: "compact"))
        guard case .array(let shorts)? = response.data?["shorts"], case .object(let first)? = shorts.first,
            case .string(let id)? = first["projectId"], let draftID = UUID(uuidString: id)
        else {
            Issue.record("нет черновика: \(String(describing: response.error))")
            return
        }
        let before = try await fixture.service.store.load(id: draftID)
        var cut = AgentEditOperation(op: "deleteWords")
        cut.words = [AgentWordRange(from: 3, to: 5)]
        cut.timeline = AgentWordCuts.fingerprint(before.clips)
        let edited = await fixture.service.applyEdits(projectID: draftID, operations: [cut])
        #expect(edited.ok, "\(String(describing: edited.error))")
        let after = try await fixture.service.store.load(id: draftID)
        #expect(after.shorts?.zooms == before.shorts?.zooms)
        #expect(after.totalDuration < before.totalDuration)
    }

    @Test("draft styling ops change the draft and undo brings it back")
    func stylingOps() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var project = fixture.project
        project.shorts = ShortsPresentation(
            title: "Шортс", reason: "", layout: .face, resolvedLayout: .face, hook: ShortsHook(text: "Было"),
            subtitles: nil, zooms: [], exportPath: nil)
        try await fixture.service.store.save(project)

        var hook = AgentEditOperation(op: "setHook")
        hook.text = "Стало"
        var layout = AgentEditOperation(op: "setLayout")
        layout.layout = "split"
        var subtitles = AgentEditOperation(op: "setSubtitles")
        subtitles.on = true
        var music = AgentEditOperation(op: "setMusic")
        music.track = "none"
        var zoom = AgentEditOperation(op: "zoom")
        zoom.words = [AgentWordRange(from: 2, to: 4)]
        zoom.timeline = fixture.timeline
        let response = await fixture.service.applyEdits(
            projectID: project.id, operations: [hook, layout, subtitles, music, zoom])
        #expect(response.ok, "\(String(describing: response.error))")
        guard case .object(let shown)? = response.data?["shorts"] else {
            Issue.record("apply_edits не показывает оформление черновика")
            return
        }
        #expect(shown["hook"] == .string("Стало"))
        let changed = try await fixture.service.store.load(id: project.id)
        #expect(changed.shorts?.hook?.text == "Стало")
        #expect(changed.shorts?.resolvedLayout == .split)
        #expect(changed.shorts?.subtitles != nil)
        #expect(!changed.music.enabled)
        #expect(changed.shorts?.zooms.count == 1)

        _ = await fixture.service.applyEdits(projectID: project.id, operations: [AgentEditOperation(op: "undo")])
        let restored = try await fixture.service.store.load(id: project.id)
        #expect(restored.shorts?.hook?.text == "Было")
    }

    @Test("a copy of a draft gets its own MP4 path and never overwrites the original")
    func copiedDraftHasOwnOutput() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var draft = fixture.project
        let original = fixture.root.appendingPathComponent("draft.mp4").path
        draft.shorts = ShortsPresentation(
            title: "Шортс", reason: "", layout: .fit, resolvedLayout: .fit, hook: nil, subtitles: nil,
            zooms: [], exportPath: original)
        try await fixture.service.store.save(draft)

        let response = await fixture.service.edit(
            AgentEditRequest(sourcePaths: [], projectID: draft.id, removePauses: false, enhanceVoice: false))
        guard case .string(let id)? = response.data?["projectId"], let copyID = UUID(uuidString: id) else {
            Issue.record("копия не создана: \(String(describing: response.error))")
            return
        }
        let copy = try await fixture.service.store.load(id: copyID)
        #expect(copy.shorts != nil)
        #expect(copy.shorts?.exportPath != original)
    }

    @Test("inspect shows the draft's styling to the agent")
    func inspectShowsShorts() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var draft = fixture.project
        draft.shorts = ShortsPresentation(
            title: "Шортс", reason: "", layout: .auto, resolvedLayout: .split, hook: ShortsHook(text: "Хук"),
            subtitles: nil,
            zooms: [ShortsZoom(sourceID: draft.clips[0].source.id, sourceStart: 2, sourceEnd: 4, scale: 1.08)],
            exportPath: "/tmp/x.mp4")
        draft.music = ShortsDraftFactory.music(track: nil, mood: "calm", variant: 0)
        try await fixture.service.store.save(draft)
        let response = await fixture.service.inspect(projectID: draft.id)
        guard case .object(let shorts)? = response.data?["shorts"] else {
            Issue.record("в inspect нет блока shorts")
            return
        }
        #expect(shorts["hook"] == .string("Хук"))
        #expect(shorts["layout"] == .string("split"))
        #expect(shorts["subtitles"] == .bool(false))
        #expect(shorts["exportPath"] == .string("/tmp/x.mp4"))
        guard case .array(let zooms)? = shorts["zooms"], case .object(let zoom)? = zooms.first else {
            Issue.record("нет наездов")
            return
        }
        #expect(zoom["timelineStart"] == .number(2))
        #expect(shorts["music"] != nil)
    }

    @Test("styling ops refuse a regular project")
    func stylingNeedsDraft() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var hook = AgentEditOperation(op: "setHook")
        hook.text = "Хук"
        let response = await fixture.service.applyEdits(projectID: fixture.project.id, operations: [hook])
        #expect(!response.ok)
    }
}

@Suite("Shorts guide for agents")
struct AgentShortsGuideTests {
    @Test("the guide teaches the agent to pick moments itself and ask the user first")
    func guideCoversShorts() {
        let guide = AgentDocumentation.guide
        for phrase in [
            "## Шортсы и Reels", "montazhka_make_shorts", "холодного зрителя", "покажите пользователю",
            "fixWords", "звук без слов", "setHook", "субтитры",
        ] {
            #expect(guide.contains(phrase), "в гайде нет «\(phrase)»")
        }
        #expect(!guide.contains("пять роликов"))
        #expect(AgentDocumentation.skill.contains("montazhka_make_shorts"))
    }
}
