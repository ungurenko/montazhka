import Foundation
import Testing

@testable import MontazhkaKit

@Suite("Inspection only loads requested audio")
struct AgentInspectionScopeTests {
    private actor Loads {
        var paths: [String] = []
        func record(_ path: String) { paths.append(path) }
    }

    private struct Fixture {
        let root: URL
        let project: Project
        let service: AgentService
        let loads: Loads
        let peaks: [Float]
    }

    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("inspection-scope-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sources = try (0..<5).map { index in
            let url = root.appendingPathComponent("source-\(index).mov")
            try Data([UInt8(index)]).write(to: url)
            return MediaReference(url: url)
        }
        let project = Project(name: "Inspection", clips: sources.map { Clip(source: $0, start: 0, end: 20) })
        let peaks = (0..<2000).map { Float($0 % 500 < 200 ? 0.5 : 0.001) }
        let loads = Loads()
        let waves = WaveformStore(
            cacheDir: root.appendingPathComponent("waves"),
            loader: { path, _ in
                await loads.record(path)
                return peaks
            })
        let service = AgentService(
            baseDirectory: root, waveforms: waves,
            startJob: { _ in
                .failure(command: "test", code: "DISABLED", message: "No external jobs.")
            })
        try await service.store.save(project)
        for source in sources {
            let cache = await service.makeTranscriptStore().cacheURL(for: source)
            try FileManager.default.createDirectory(
                at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            let words = [
                TranscriptWord(sourceID: source.id, text: "first", start: 0.2, end: 0.4, confidence: 1),
                TranscriptWord(sourceID: source.id, text: "second", start: 1.2, end: 1.4, confidence: 1),
            ]
            try JSONEncoder().encode(TranscriptDocument(words: words)).write(to: cache)
        }
        return Fixture(root: root, project: project, service: service, loads: loads, peaks: peaks)
    }

    @Test(arguments: [
        TimelineRange(from: 1, to: 10), TimelineRange(from: 18, to: 22),
        TimelineRange(from: 40, to: 50), TimelineRange(from: -5, to: 2),
        TimelineRange(from: 12, to: 1), TimelineRange(from: 100, to: 200),
        TimelineRange(from: 0, to: 100),
    ])
    func audioPreservesFullClipPausesAndOnlyLoadsIntersections(request: TimelineRange) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let result = await f.service.audio(
            target: AgentMediaTarget(projectID: f.project.id), from: request.from, to: request.to, buckets: 60)
        #expect(result.ok)
        let range = LoudnessProbe.normalizedRange(total: 100, from: request.from, to: request.to)
        let paths = await f.loads.paths
        #expect(Set(paths) == LoudnessProbe.sourcePaths(clips: f.project.clips, range: range))
        #expect(paths.count == Set(paths).count)
        let original = SilenceDetector.findPauses(
            clips: f.project.clips, peaksFor: { _ in f.peaks },
            settings: DetectionSettings(minPauseDuration: 0.4, paddingMS: 0)
        )
        .filter { $0.fullEnd > range.from && $0.fullStart < range.to }
        .map {
            AgentJSONValue.object([
                "from": .number(AgentService.rounded(max(range.from, $0.fullStart))),
                "to": .number(AgentService.rounded(min(range.to, $0.fullEnd))),
            ])
        }
        #expect(result.data?["silences"] == .array(original))
        #expect(result.data?["from"] == .number(range.from))
        #expect(result.data?["to"] == .number(range.to))
        let eager = WaveformStore(cacheDir: f.root.appendingPathComponent("eager"), loader: { _, _ in f.peaks })
        for clip in f.project.clips { await eager.ensure(path: clip.sourcePath) }
        let reference = AgentService(baseDirectory: f.root, waveforms: eager)
        let full = await reference.audio(
            target: AgentMediaTarget(projectID: f.project.id), from: request.from, to: request.to, buckets: 60)
        #expect(result == full)
    }

    @Test(arguments: [false, true])
    func transcriptOnlyLoadsPageSources(phrases: Bool) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let request = AgentTranscriptRequest(
            target: AgentMediaTarget(projectID: f.project.id), from: 0, to: 10, phrases: phrases)
        let result = await f.service.transcript(request)
        #expect(result.ok)
        #expect(result.data?["wordCount"] == .number(2))
        let loaded = await f.loads.paths
        #expect(loaded == (phrases ? [] : [f.project.clips[0].sourcePath]))
        if !phrases, case .string(let text)? = result.data?["text"] {
            #expect(text.contains("звук без слов"))
        }
        let eager = WaveformStore(cacheDir: f.root.appendingPathComponent("eager"), loader: { _, _ in f.peaks })
        for clip in f.project.clips { await eager.ensure(path: clip.sourcePath) }
        let expected = await AgentService(baseDirectory: f.root, waveforms: eager).transcript(request)
        #expect(result == expected)
        _ = await f.service.transcript(AgentTranscriptRequest(target: request.target, from: 200, to: 300))
        #expect(await f.loads.paths == loaded)
    }

    @Test
    func repeatedSourceAcrossTimelineIsDecodedOnce() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var project = f.project
        project.clips = [f.project.clips[0], Clip(source: f.project.clips[0].source, start: 0, end: 20)]
        try await f.service.store.save(project)
        let result = await f.service.transcript(AgentTranscriptRequest(target: AgentMediaTarget(projectID: project.id)))
        #expect(result.ok)
        let paths = await f.loads.paths
        #expect(paths == [project.clips[0].sourcePath])
        if case .string(let text)? = result.data?["text"] { #expect(text.contains("склейка")) }
    }
}
