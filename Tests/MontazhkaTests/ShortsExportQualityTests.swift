@preconcurrency import AVFoundation
import Foundation
import Testing

@testable import MontazhkaKit

/// Выбранное качество управляет размером кадра черновика шортса одинаково в окне и у агента.
@Suite("Shorts draft export quality")
struct ShortsExportQualityTests {
    private struct Fixture {
        let root: URL
        let store: ProjectStore
        let project: Project
    }

    /// Секунда Full HD — достаточно большой исходник, чтобы качество уменьшало кадр.
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-quality-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let video = root.appendingPathComponent("wide.mov")
        let frame = try TestOverlayFactory.pixelBuffer(width: 1920, height: 1080, format: kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(frame, [])
        memset(CVPixelBufferGetBaseAddress(frame), 0x60, CVPixelBufferGetDataSize(frame))
        CVPixelBufferUnlockBaseAddress(frame, [])
        try await TestOverlayFactory.writeStill(
            frame,
            settings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1920, AVVideoHeightKey: 1080],
            fileType: .mov, frameCount: 30, frameDuration: CMTime(value: 1, timescale: 30), to: video)
        var project = Project(name: "Шортс", clips: [Clip(sourceURL: video, start: 0, end: 1)])
        project.shorts = ShortsPresentation(
            title: "Шортс", reason: "", layout: .fit, resolvedLayout: .fit, hook: nil, subtitles: nil,
            zooms: [], exportPath: root.appendingPathComponent("draft.mp4").path)
        let store = ProjectStore(baseDirectory: root)
        try await store.save(project)
        return Fixture(root: root, store: store, project: project)
    }

    private func videoSize(_ url: URL) async throws -> CGSize {
        let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
        return try await track.load(.naturalSize)
    }

    @MainActor
    @Test("compact is vertical HD 720 and high is Full HD, in the window as for the agent")
    func windowFollowsQuality() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let controller = EditorController(
            project: fixture.project, store: fixture.store, openRouterKeyStore: EmptyOpenRouterKeyStore())

        let compact = try await controller.prepareExport(quality: .compact, step: { _ in })
        let high = try await controller.prepareExport(quality: .high, step: { _ in })

        #expect(compact.videoComposition?.renderSize == CGSize(width: 720, height: 1280))
        #expect(high.videoComposition?.renderSize == CGSize(width: 1080, height: 1920))
        let windowFile = fixture.root.appendingPathComponent("window.mp4")
        _ = try await TranscodingVideoExporter().export(compact, quality: .compact, to: windowFile, progress: { _ in })
        let agentFile = fixture.root.appendingPathComponent("agent.mp4")
        let response = await AgentService(baseDirectory: fixture.root).export(
            projectID: fixture.project.id, outputPath: agentFile.path, quality: "compact",
            final: false, confirmFinal: false, overwrite: false)
        #expect(response.ok, "\(String(describing: response.error))")
        #expect(try await videoSize(windowFile) == CGSize(width: 720, height: 1280))
        #expect(try await videoSize(agentFile) == CGSize(width: 720, height: 1280), "окно и агент совпадают")
        await controller.stop()
    }
}
