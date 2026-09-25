@preconcurrency import AVFoundation
import Foundation
import ImageIO
import Testing

@testable import MontazhkaKit

@Suite("Shorts draft renderer")
struct ShortsRendererTests {
    private struct Fixture {
        let root: URL
        let service: AgentService
        let project: Project
    }

    private func fixture(
        hook: String? = "Монтаж за минуту", codec: AVVideoCodecType = .h264
    ) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let video = root.appendingPathComponent("talk.mov")
        try await TestVideoFactory.make(
            segments: [(duration: 5, loud: true)], videoLuma: 150, codec: codec, to: video)
        let media = MediaReference(url: video)
        var project = Project(
            name: "Шортс", clips: [Clip(source: media, start: 0.5, end: 2), Clip(source: media, start: 3, end: 4.5)])
        project.shorts = ShortsPresentation(
            title: "Шортс", reason: "", layout: .face, resolvedLayout: .face,
            hook: hook.map { ShortsHook(text: $0) }, subtitles: nil,
            zooms: [ShortsZoom(sourceID: media.id, sourceStart: 1, sourceEnd: 1.8, scale: 1.1)],
            exportPath: root.appendingPathComponent("draft.mp4").path)
        let service = AgentService(baseDirectory: root)
        try await service.store.save(project)
        return Fixture(root: root, service: service, project: project)
    }

    @Test("a draft renders on a vertical canvas; only the export has baked text")
    func planHasVerticalCanvas() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plan = try await ShortsRenderer.plan(
            project: fixture.project, words: [], faces: FaceTrackStore(cacheDir: fixture.root), quality: .compact)
        let size = plan.frameComposition.renderSize
        #expect(size.height > size.width)
        #expect(abs(size.width / size.height - 9.0 / 16.0) < 0.01)
        #expect(plan.exportComposition.animationTool != nil)
        #expect(plan.frameComposition.animationTool == nil)
    }

    @Test("montazhka_export of a draft writes a vertical MP4 to the draft path")
    func agentExportUsesDraftRenderer() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let response = await fixture.service.export(
            projectID: fixture.project.id, outputPath: nil, quality: "compact",
            final: false, confirmFinal: false, overwrite: false)
        #expect(response.ok, "\(String(describing: response.error))")
        let path = try #require(fixture.project.shorts?.exportPath)
        #expect(response.data?["path"] == .string(path))
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let natural = try await track.load(.naturalSize)
        #expect(natural.height > natural.width)
        #expect(abs(try await asset.load(.duration).seconds - fixture.project.totalDuration) < 0.25)

        let again = await fixture.service.export(
            projectID: fixture.project.id, outputPath: nil, quality: "compact",
            final: false, confirmFinal: false, overwrite: false)
        #expect(again.ok, "повторный экспорт черновика перезаписывает его файл")
    }

    @Test("frames of a draft show the vertical result", arguments: [AVVideoCodecType.h264, .hevc])
    func framesAreVertical(codec: AVVideoCodecType) async throws {
        let fixture = try await fixture(codec: codec)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let response = await fixture.service.frames(
            AgentFramesRequest(
                target: AgentMediaTarget(projectID: fixture.project.id, filePath: nil),
                from: nil, to: nil, count: 1, times: [], aroundCuts: false))
        #expect(response.ok, "\(String(describing: response.error))")
        guard case .number(let width)? = response.data?["width"], case .number(let height)? = response.data?["height"]
        else {
            Issue.record("нет размеров сетки")
            return
        }
        #expect(height > width)
        guard case .string(let path)? = response.data?["imagePath"],
            let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
            let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            Issue.record("сетка кадров не читается")
            return
        }
        #expect(brightness(of: sheet, atX: 0.5, y: 0.5) > 60, "кадр черновика не должен быть чёрным")
    }

    /// Яркость пикселя 0…255 в точке (доли ширины и высоты).
    private func brightness(of image: CGImage, atX x: Double, y: Double) -> Int {
        guard
            let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let data = context.data
        else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
        let offset = (Int(Double(image.height) * y) * image.width + Int(Double(image.width) * x)) * 4
        return (Int(pixels[offset]) + Int(pixels[offset + 1]) + Int(pixels[offset + 2])) / 3
    }
}

@Suite("Window export of a shorts draft")
struct ShortsWindowExportTests {
    @MainActor
    @Test("a prepared export with a vertical composition is written vertically")
    func exporterHonoursVideoComposition() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("talk.mov")
        try await TestVideoFactory.make(segments: [(duration: 3, loud: true)], to: video)
        var project = Project(name: "Шортс", clips: [Clip(sourceURL: video, start: 0, end: 2)])
        project.shorts = ShortsPresentation(
            title: "Шортс", reason: "", layout: .face, resolvedLayout: .face, hook: nil, subtitles: nil,
            zooms: [], exportPath: nil)
        let plan = try await ShortsRenderer.plan(
            project: project, words: [], faces: FaceTrackStore(cacheDir: root), quality: .compact)
        let prepared = PreparedExport(
            composition: plan.composition, audioMix: plan.audioMix, warning: nil,
            videoComposition: plan.exportComposition)
        let output = root.appendingPathComponent("out.mp4")
        try await TranscodingVideoExporter().export(prepared, quality: .compact, to: output, progress: { _ in })
        let track = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(size.height > size.width)
    }
}
