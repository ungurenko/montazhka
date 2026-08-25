import AVFoundation
import Foundation
import Testing

@testable import MontazhkaKit

@Suite
struct MediaPipelineActorTests {
    @Test
    func testRenderBuildsCompositionMatchingSourceDurationWithoutWarnings() async throws {
        let videoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pipeline-render-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: videoURL) }
        try await TestVideoFactory.make(
            segments: [(duration: 1.0, loud: true), (duration: 1.5, loud: false)],
            to: videoURL)

        let asset = AVURLAsset(url: videoURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let videoTrack = try #require(videoTracks.first)
        let sourceDuration = try await videoTrack.load(.timeRange).duration.seconds

        let project = Project(
            name: "pipeline",
            clips: [Clip(sourceURL: videoURL, start: 0, end: sourceDuration)])
        let pipeline = makePipeline()
        let request = MediaRenderRequest(
            project: project, mode: .preview, readyEnhancedAudio: [:])

        let result = await pipeline.render(request)

        #expect(result.warnings.isEmpty, "\(result.warnings.map(\.message))")
        #expect(abs((result.composition.duration.seconds) - (sourceDuration)) <= (0.05))
    }

    @Test
    func testRenderReportsMissingVideoWarningForMissingSource() async {
        let missingPath = "/tmp/montazhka-pipeline-missing-\(UUID().uuidString).mov"
        let project = Project(
            name: "missing",
            clips: [Clip(sourcePath: missingPath, start: 0, end: 5)])
        let pipeline = makePipeline()
        let request = MediaRenderRequest(
            project: project, mode: .preview, readyEnhancedAudio: [:])

        let result = await pipeline.render(request)

        #expect(
            result.warnings.contains(
                .missingVideo((URL(fileURLWithPath: missingPath).deletingPathExtension().lastPathComponent))))
        #expect(abs((result.composition.duration.seconds) - (0)) <= (0.001))
    }

    private func makePipeline() -> MediaPipeline {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-pipeline-\(UUID().uuidString)")
        return MediaPipeline(
            voiceStore: VoiceEnhanceStore(cacheDir: root),
            musicEQStore: MusicEQStore(cacheDir: root))
    }
}
