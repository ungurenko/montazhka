@preconcurrency import AVFoundation
import Foundation
import Testing

@testable import MontazhkaKit

@Suite("Project final assembly")
struct FinalAssemblyTests {
    @Test("legacy preferences keep a zero tail; tail participates in provenance")
    func preferencesAndFingerprint() throws {
        let old = try JSONDecoder().decode(ExportPreferences.self, from: Data("{}".utf8))
        #expect(old.freezeTailSeconds == 0)
        var project = Project(name: "test", clips: [Clip(sourcePath: "/tmp/test.mov", start: 0, end: 2)])
        let before = ExportProvenance.fingerprint(for: project)
        project.export.freezeTailSeconds = 0.5
        #expect(project.totalDuration == 2.5)
        #expect(ExportProvenance.fingerprint(for: project) != before)
    }

    @Test("opaque video requires explicit cover mode")
    func explicitCover() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mov")
        try await TestVideoFactory.make(segments: [(duration: 1, loud: true)], to: source)
        await #expect(throws: (any Error).self) {
            try await OverlayMediaProbe.validate(source, projectFrame: CGSize(width: 1920, height: 1080))
        }
        let result = try await OverlayMediaProbe.validate(
            source, projectFrame: CGSize(width: 1920, height: 1080), mode: .cover)
        #expect(result.duration > 0.9)
    }

    @Test("freeze appends a still picture without replaying the voice")
    func freezeComposition() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mov")
        try await TestVideoFactory.make(segments: [(duration: 2, loud: true)], to: source)
        let built = await CompositionBuilder.buildResult(
            clips: [Clip(sourceURL: source, start: 0, end: 2)], freezeTailSeconds: 0.5)
        #expect(abs(built.composition.duration.seconds - 2.5) < 0.01)
        let audio = try #require(try await built.composition.loadTracks(withMediaType: .audio).first)
        #expect(try await audio.load(.timeRange).duration.seconds <= 2.01)
    }

    @Test("the exported MP4 includes the whole frozen tail and remains checkable")
    func exportedTail() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mov")
        try await TestVideoFactory.make(segments: [(duration: 2, loud: true)], to: source)
        var project = Project(name: "test", clips: [Clip(sourceURL: source, start: 0, end: 2)])
        project.export.freezeTailSeconds = 0.5
        let service = AgentService(baseDirectory: root)
        try await service.store.save(project)
        let result = await MediaPipeline(
            voiceStore: VoiceEnhanceStore(cacheDir: root), musicEQStore: MusicEQStore(cacheDir: root)
        ).render(
            MediaRenderRequest(project: project, mode: .export, readyEnhancedAudio: [:]))
        let input = ExportInput(
            composition: result.composition, audioMix: result.audioMix,
            videoComposition: result.videoPlan?.frameComposition)
        let output = root.appendingPathComponent("final.mp4")
        try await Transcoder.export(
            input: input, settings: Transcoder.settings(for: .compact, input: input), to: output,
            metadata: ExportProvenance.metadataItems(fingerprint: ExportProvenance.fingerprint(for: project))
        ) { _ in }
        let seconds = try await AVURLAsset(url: output).load(.duration).seconds
        #expect(abs(seconds - 2.5) < 0.05)
        let checked = await service.check(AgentCheckRequest(projectID: project.id, filePath: output.path, words: false))
        #expect(checked.ok)
        #expect(checked.data?["match"] == .string("confirmed"))
    }
}

@Suite("Pipeline safety contracts")
struct PipelineSafetyTests {
    @Test("a stale timeline rejects the whole batch without changing clips")
    func staleTimeline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mov")
        try await TestVideoFactory.make(segments: [(duration: 2, loud: true)], to: source)
        let project = Project(name: "test", clips: [Clip(sourceURL: source, start: 0, end: 2)])
        let service = AgentService(baseDirectory: root)
        try await service.store.save(project)
        let ops = try AgentEditOperation.decodeList(
            Data(#"[{"op":"delete","ranges":[{"from":0,"to":1}],"expectedTimeline":"stale"}]"#.utf8))
        #expect(await service.applyEdits(projectID: project.id, operations: ops).ok == false)
        #expect(try await service.store.load(id: project.id).clips == project.clips)
    }

    @Test("privacy candidates classify without treating ordinary words as secrets")
    func privacyClassification() {
        #expect(SourceAnalysis.privacyKind("email@example.invalid") == "email")
        #expect(SourceAnalysis.privacyKind("token=SYNTHETIC_TEST_VALUE") == "credential")
        #expect(SourceAnalysis.privacyKind("обычный текст урока") == nil)
    }
}
