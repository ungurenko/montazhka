@preconcurrency import AVFoundation
import Foundation
import QuartzCore
import Testing

@testable import MontazhkaKit

/// Готовый MP4 помнит, из какой версии проекта он собран: проверка файла потом сверяет отпечаток.
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

    @Test("the project fingerprint follows everything that shapes the file and nothing else")
    func fingerprintCoversWhatShapesTheFile() {
        let source = MediaReference(path: "/tmp/talk.mov")
        var base = Project(name: "Ролик", clips: [Clip(source: source, start: 0, end: 4)])
        base.shorts = ShortsPresentation(
            title: "Шортс", reason: "", layout: .fit, resolvedLayout: .fit, hook: nil, subtitles: nil, zooms: [],
            exportPath: "/tmp/a.mp4")
        let print = ExportProvenance.fingerprint(for: base)

        var unrelated = base
        unrelated.name = "Другое имя"
        unrelated.updatedAt = Date(timeIntervalSince1970: 0)
        unrelated.detection.thresholdDB = -30
        unrelated.shorts?.exportPath = "/tmp/b.mp4"
        #expect(ExportProvenance.fingerprint(for: unrelated) == print, "имя, даты, поиск пауз и путь MP4 не в счёт")

        let changes: [(String, (inout Project) -> Void)] = [
            ("лента", { $0.clips[0].end = 3 }),
            (
                "анимация",
                {
                    $0.overlays = [
                        ProjectOverlay(
                            id: UUID(), media: MediaReference(path: "/tmp/a.mov"),
                            anchor: OverlayAnchor(sourceID: source.id, sourceTime: 1, wordText: nil), align: .start,
                            payoffAt: 0, duration: 1, position: .full, scale: 1)
                    ]
                }
            ),
            ("вшитые субтитры", { $0.export.burnSubtitles = true }),
            ("громкость", { $0.export.normalizeLoudness = false }),
            ("музыка", { $0.music.enabled = true }),
            ("приглушение музыки", { $0.music.ducking = true }),
            ("улучшение голоса", { $0.voiceEnhance.enabled = true }),
            ("хук шортса", { $0.shorts?.hook = ShortsHook(text: "Хук") }),
        ]
        for (name, change) in changes {
            var changed = base
            change(&changed)
            #expect(ExportProvenance.fingerprint(for: changed) != print, "\(name) меняет файл")
        }
    }
}
