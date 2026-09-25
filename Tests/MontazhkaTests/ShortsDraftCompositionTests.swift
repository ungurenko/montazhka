@preconcurrency import AVFoundation
import Foundation
import Testing

@testable import MontazhkaKit

@Suite("Shorts draft video composition")
struct ShortsDraftCompositionTests {
    private func build(layout: ShortsDraftLayout) async throws -> (AVMutableComposition, AVMutableVideoComposition, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let video = root.appendingPathComponent("talk.mov")
        try await TestVideoFactory.make(segments: [(duration: 4, loud: true)], to: video)
        let source = MediaReference(url: video)
        let clips = [Clip(source: source, start: 0, end: 1.5), Clip(source: source, start: 2.5, end: 4)]
        let built = await CompositionBuilder.buildResult(clips: clips, videoCopies: layout == .split ? 2 : 1)
        let zoom = ShortsZoom(sourceID: source.id, sourceStart: 0.5, sourceEnd: 1.2, scale: 1.1)
        let videoComposition = try await ShortsDraftVideoComposition.make(
            asset: built.composition, clips: clips, layout: layout,
            centre: { _, _ in CGPoint(x: 0.5, y: 0.4) }, zooms: [zoom],
            faceBox: CGRect(x: 0.8, y: 0.7, width: 0.1, height: 0.18),
            canvas: CGSize(width: 180, height: 320))
        return (built.composition, videoComposition, root)
    }

    @Test("a face draft renders one moving picture on a 9:16 canvas")
    func faceComposition() async throws {
        let (composition, video, root) = try await build(layout: .face)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(video.renderSize == CGSize(width: 180, height: 320))
        let instruction = try #require(video.instructions.first as? AVVideoCompositionInstruction)
        #expect(instruction.layerInstructions.count == 1)
        #expect(abs(instruction.timeRange.duration.seconds - composition.duration.seconds) < 0.05)
    }

    @Test("a split draft uses two copies of the picture")
    func splitComposition() async throws {
        let (composition, video, root) = try await build(layout: .split)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(composition.tracks(withMediaType: .video).count == 2)
        let instruction = try #require(video.instructions.first as? AVVideoCompositionInstruction)
        #expect(instruction.layerInstructions.count == 2)
    }

    @Test("the draft exports to a vertical MP4 of the right length")
    func exportsVertical() async throws {
        let (composition, video, root) = try await build(layout: .face)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        try await Transcoder.exportWithOfflineComposition(
            input: ExportInput(composition: composition, audioMix: nil, videoComposition: video),
            settings: Transcoder.Settings(dimensions: video.renderSize, videoBitrate: 1_000_000, audioBitrate: 64_000),
            to: output, progress: { _ in })
        let asset = AVURLAsset(url: output)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 180, height: 320))
        #expect(abs(try await asset.load(.duration).seconds - 3) < 0.15)
    }
}
