@preconcurrency import AVFoundation
import Foundation
import QuartzCore
import Testing

@testable import MontazhkaKit

/// Готовый MP4 помнит, из какой ленты он собран: проверка файла потом сверяет отпечаток.
@Suite("Export provenance")
struct ExportProvenanceTests {
    private struct Source {
        let root: URL
        let input: ExportInput
        let settings: Transcoder.Settings
    }

    private func source() async throws -> Source {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-provenance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let video = root.appendingPathComponent("talk.mov")
        try await TestVideoFactory.make(segments: [(duration: 2, loud: true)], to: video)
        let built = await CompositionBuilder.build(clips: [Clip(sourceURL: video, start: 0, end: 2)])
        let input = ExportInput(composition: built.composition, audioMix: built.audioMix)
        return Source(root: root, input: input, settings: try await Transcoder.settings(for: .compact, input: input))
    }

    @Test("the direct writer tags the MP4 with the timeline fingerprint")
    func directWriterKeepsFingerprint() async throws {
        let source = try await source()
        defer { try? FileManager.default.removeItem(at: source.root) }
        let output = source.root.appendingPathComponent("direct.mp4")

        try await Transcoder.export(
            input: source.input, settings: source.settings, to: output,
            metadata: ExportProvenance.metadataItems(fingerprint: "lenta-1")
        ) { _ in }

        #expect(await ExportProvenance.read(url: output) == "lenta-1")
    }

    @Test("the two-pass export with baked layers carries the fingerprint into the final file")
    func offlineCompositionKeepsFingerprint() async throws {
        let source = try await source()
        defer { try? FileManager.default.removeItem(at: source.root) }
        let videoComposition = try await AVMutableVideoComposition.videoComposition(
            withPropertiesOf: source.input.composition)
        let frame = CGRect(origin: .zero, size: videoComposition.renderSize)
        let parent = CALayer()
        let videoLayer = CALayer()
        parent.frame = frame
        videoLayer.frame = frame
        parent.addSublayer(videoLayer)
        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer, in: parent)
        let output = source.root.appendingPathComponent("baked.mp4")

        try await Transcoder.exportWithOfflineComposition(
            input: ExportInput(
                composition: source.input.composition, audioMix: source.input.audioMix,
                videoComposition: videoComposition),
            settings: source.settings, to: output,
            metadata: ExportProvenance.metadataItems(fingerprint: "lenta-2")
        ) { _ in }

        #expect(await ExportProvenance.read(url: output) == "lenta-2")
    }

    @Test("a file written without a fingerprint has none")
    func untaggedFileHasNoFingerprint() async throws {
        let source = try await source()
        defer { try? FileManager.default.removeItem(at: source.root) }
        let output = source.root.appendingPathComponent("plain.mp4")

        try await Transcoder.export(input: source.input, settings: source.settings, to: output) { _ in }

        #expect(await ExportProvenance.read(url: output) == nil)
        #expect(await ExportProvenance.read(url: source.root.appendingPathComponent("missing.mp4")) == nil)
    }
}
