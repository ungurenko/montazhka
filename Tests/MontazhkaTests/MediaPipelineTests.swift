import AVFoundation
import XCTest
@testable import Montazhka

final class MediaPipelineTests: XCTestCase {
    func testManyFragmentsOfOneVideoLoadOneSourceAndBuildWholeTimeline() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-many-fragments-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await TestVideoFactory.make(segments: [(duration: 12, loud: true)], to: url)

        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let videoTrack = try XCTUnwrap(videoTracks.first)
        let mediaDuration = try await videoTrack.load(.timeRange).duration.seconds
        let source = MediaReference(url: url)
        let fragmentDuration = mediaDuration / 185.0
        let clips = (0..<185).map { index in
            let start = Double(index) * fragmentDuration
            let end = index == 184 ? mediaDuration : Double(index + 1) * fragmentDuration
            return Clip(source: source, start: start, end: end)
        }

        let plan = MediaSourceLoadPlan(clips: clips, enhancedAudio: [:])
        XCTAssertEqual(plan.sources.count, 1)

        let result = await CompositionBuilder.buildResult(clips: clips)
        XCTAssertEqual(result.composition.duration.seconds, mediaDuration, accuracy: 0.05)
        XCTAssertTrue(result.warnings.isEmpty, "\(result.warnings.map(\.message))")
    }

    func testCompositionReportsMissingVideoInsteadOfSilentlySkippingIt() async {
        let clip = Clip(sourcePath: "/tmp/montazhka-definitely-missing.mov", start: 0, end: 5)

        let result = await CompositionBuilder.buildResult(clips: [clip])

        XCTAssertTrue(result.warnings.contains(.missingVideo(clip.fileName)))
        XCTAssertEqual(result.composition.duration.seconds, 0, accuracy: 0.001)
    }
}
