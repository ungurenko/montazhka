import Foundation
import Testing

@testable import MontazhkaKit

@Suite("Agent timeline editing")
struct AgentTimelineEditTests {
    private let a = "/tmp/a.mov"
    private let b = "/tmp/b.mov"
    private var durations: [String: Double] { [a: 10, b: 20] }

    private func ranges(_ clips: [Clip]) -> [[Double]] {
        clips.map { [$0.start, $0.end] }
    }

    @Test("delete ranges are measured against the timeline before the operation")
    func deleteUsesTimelineBeforeOperation() throws {
        let clips = [Clip(sourcePath: a, start: 0, end: 10)]
        let result = try TimelineEditOps.apply(
            [.delete(ranges: [TimelineRange(from: 2, to: 3), TimelineRange(from: 6, to: 8)])],
            to: clips, sourceDurations: durations)
        #expect(ranges(result) == [[0, 2], [3, 6], [8, 10]])
    }

    @Test("overlapping delete ranges remove only their union")
    func overlappingDeletes() throws {
        let clips = [Clip(sourcePath: a, start: 0, end: 10)]
        let result = try TimelineEditOps.apply(
            [.delete(ranges: [TimelineRange(from: 2, to: 5), TimelineRange(from: 4, to: 7)])],
            to: clips, sourceDurations: durations)
        #expect(ranges(result) == [[0, 2], [7, 10]])
    }

    @Test("loudness never splits the range finer than one waveform window")
    func loudnessBucketResolution() {
        let report = LoudnessProbe.measure(
            clips: [Clip(sourcePath: a, start: 0, end: 1)],
            peaksFor: { _ in [Float](repeating: 0.5, count: 100) }, from: 0, to: 0.1, buckets: 60)
        #expect(report.levelsDB.count == 10)
        #expect(!report.levelsDB.contains(LoudnessProbe.floorDB))
    }

    @Test("operations run in order and each sees the previous result")
    func operationsRunInOrder() throws {
        let clips = [Clip(sourcePath: a, start: 0, end: 10)]
        let result = try TimelineEditOps.apply(
            [.split(at: 4), .move(clip: 1, to: 0)], to: clips, sourceDurations: durations)
        #expect(ranges(result) == [[4, 10], [0, 4]])
    }

    @Test("trim shortens and extends an edge inside the source")
    func trimEdges() throws {
        let clips = [Clip(sourcePath: a, start: 2, end: 8)]
        let shorter = try TimelineEditOps.apply(
            [.trim(clip: 0, edge: .start, seconds: 1)], to: clips, sourceDurations: durations)
        #expect(ranges(shorter) == [[3, 8]])
        let longer = try TimelineEditOps.apply(
            [.trim(clip: 0, edge: .end, seconds: -2)], to: clips, sourceDurations: durations)
        #expect(ranges(longer) == [[2, 10]])
        #expect(throws: TimelineEditError.beyondSource(0)) {
            try TimelineEditOps.apply(
                [.trim(clip: 0, edge: .end, seconds: -3)], to: clips, sourceDurations: durations)
        }
    }

    @Test("insert splits a clip and puts a piece of another source inside")
    func insertInsideClip() throws {
        let clips = [Clip(sourcePath: a, start: 0, end: 10)]
        let result = try TimelineEditOps.apply(
            [.insert(sourcePath: b, start: 5, end: 7, at: 4)], to: clips, sourceDurations: durations)
        #expect(result.map(\.sourcePath) == [a, b, a])
        #expect(ranges(result) == [[0, 4], [5, 7], [4, 10]])
        let appended = try TimelineEditOps.apply(
            [.insert(sourcePath: b, start: 0, end: 1, at: 10)], to: clips, sourceDurations: durations)
        #expect(appended.last?.sourcePath == b)
    }

    @Test("invalid operations fail loudly instead of changing the timeline")
    func invalidOperations() {
        let clips = [Clip(sourcePath: a, start: 0, end: 10)]
        #expect(throws: TimelineEditError.noClip(3)) {
            try TimelineEditOps.apply([.move(clip: 3, to: 0)], to: clips, sourceDurations: durations)
        }
        #expect(throws: TimelineEditError.invalidRange(5, 4)) {
            try TimelineEditOps.apply(
                [.delete(ranges: [TimelineRange(from: 5, to: 4)])], to: clips, sourceDurations: durations)
        }
        #expect(throws: TimelineEditError.emptyTimeline) {
            try TimelineEditOps.apply(
                [.delete(ranges: [TimelineRange(from: 0, to: 10)])], to: clips, sourceDurations: durations)
        }
    }

    @Test("revisions undo several steps and survive a new store")
    func revisionUndo() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-revisions-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var project = Project(name: "Ревизии", clips: [Clip(sourcePath: a, start: 0, end: 10)])
        let store = AgentRevisionStore(baseDirectory: root)
        #expect(try await store.push(project) == 1)
        project.clips = [Clip(sourcePath: a, start: 0, end: 5)]
        #expect(try await store.push(project) == 2)

        let reopened = AgentRevisionStore(baseDirectory: root)
        let restored = try await reopened.snapshot(projectID: project.id, steps: 2)
        #expect(restored.totalDuration == 10)
        #expect(await reopened.revision(of: project.id) == 2)
        await reopened.drop(projectID: project.id, steps: 2)
        #expect(await reopened.revision(of: project.id) == 0)
        await #expect(throws: AgentRevisionError.self) {
            try await reopened.snapshot(projectID: project.id, steps: 1)
        }
    }

    @Test("loudness maps timeline ranges onto clips and finds silence")
    func loudnessProbe() {
        // 100 окон в секунду: 0–2 с громко, 2–3 с тишина, 3–4 с громко.
        let loud = [Float](repeating: 0.5, count: 100)
        let peaks = loud + loud + [Float](repeating: 0, count: 100) + loud
        // Второй клип начинается с тишины исходника, поэтому на ленте она стоит на 1–2 с.
        let clips = [Clip(sourcePath: a, start: 0, end: 1), Clip(sourcePath: a, start: 2, end: 4)]
        let report = LoudnessProbe.measure(
            clips: clips, peaksFor: { _ in peaks }, from: 0, to: 3, buckets: 3,
            settings: DetectionSettings(minPauseDuration: 0.4, paddingMS: 0))
        #expect(report.levelsDB.count == 3)
        #expect(report.levelsDB[0] > -7)
        #expect(report.levelsDB[1] == LoudnessProbe.floorDB)
        #expect(report.levelsDB[2] > -7)
        #expect(report.silences == [LoudnessReport.Silence(from: 1, to: 2)])
    }

    @Test("operations decode from a bare list and from a wrapper object")
    func operationDecoding() throws {
        let list = try AgentEditOperation.decodeList(Data(#"[{"op":"split","at":2}]"#.utf8))
        #expect(try list[0].timelineOp() == .split(at: 2))
        let wrapped = try AgentEditOperation.decodeList(
            Data(#"{"operations":[{"op":"delete","ranges":[{"from":1,"to":2}]}]}"#.utf8))
        #expect(try wrapped[0].timelineOp() == .delete(ranges: [TimelineRange(from: 1, to: 2)]))
        #expect(throws: AgentServiceError.self) {
            try AgentEditOperation(op: "trim").timelineOp()
        }
    }
}
