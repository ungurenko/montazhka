@preconcurrency import AVFoundation
import CoreVideo
import Foundation
import Testing

@testable import MontazhkaKit

/// Лента из разных исходников: у каждого куска свой поворот и размер. Кадр ролика —
/// как у первого куска, остальные вписываются в него целиком с чёрными полями,
/// и в предпросмотре, и в готовом MP4.
@Suite("Mixed source geometry")
struct MixedGeometryTests {
    private static let bright: UInt8 = 200
    private static let dark: UInt8 = 40
    private static let gray: UInt8 = 128

    private struct Scene {
        let root: URL
        let landscape: URL
        let portrait: URL

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    /// Горизонтальный серый 320×180 и «вертикальный» 320×180 с поворотом 90°, как у съёмки
    /// iPhone: левая половина кадра светлая, правая тёмная — после поворота светлый верх.
    private func scene() async throws -> Scene {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-geometry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let landscape = root.appendingPathComponent("landscape.mov")
        try await still(to: landscape, transform: .identity) { _ in Self.gray }
        let portrait = root.appendingPathComponent("portrait.mov")
        try await still(to: portrait, transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 180, ty: 0)) {
            $0 < 160 ? Self.bright : Self.dark
        }
        return Scene(root: root, landscape: landscape, portrait: portrait)
    }

    private func still(to url: URL, transform: CGAffineTransform, luma: (Int) -> UInt8) async throws {
        let (width, height) = (320, 180)
        let frame = try TestOverlayFactory.pixelBuffer(width: width, height: height, format: kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(frame, [])
        let base = try #require(CVPixelBufferGetBaseAddress(frame)).assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(frame)
        for y in 0..<height {
            for x in 0..<width {
                let value = luma(x)
                let pixel = base + y * rowBytes + x * 4
                (pixel[0], pixel[1], pixel[2], pixel[3]) = (value, value, value, 255)
            }
        }
        CVPixelBufferUnlockBaseAddress(frame, [])
        try await TestOverlayFactory.writeStill(
            frame,
            settings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height],
            fileType: .mov, frameCount: 30, frameDuration: CMTime(value: 1, timescale: 30), transform: transform,
            to: url)
    }

    private func render(_ clips: [URL], root: URL) async -> MediaRenderResult {
        let project = Project(name: "Смесь", clips: clips.map { Clip(sourceURL: $0, start: 0, end: 1) })
        return await MediaPipeline(
            voiceStore: VoiceEnhanceStore(cacheDir: root.appendingPathComponent("voice")),
            musicEQStore: MusicEQStore(cacheDir: root.appendingPathComponent("eq"))
        ).render(MediaRenderRequest(project: project, mode: .preview, readyEnhancedAudio: [:]))
    }

    /// Что видит плеер: своя картинка ленты, а без неё — как AVPlayer собрал бы сам.
    private func previewComposition(_ result: MediaRenderResult) async throws -> AVVideoComposition {
        if let frame = result.videoPlan?.frameComposition { return frame }
        return try await AVMutableVideoComposition.videoComposition(withPropertiesOf: result.composition)
    }

    private func export(_ result: MediaRenderResult, to url: URL) async throws {
        let job = FinalExportJob(
            input: ExportInput(
                composition: result.composition, audioMix: result.audioMix,
                videoComposition: result.videoPlan?.frameComposition),
            quality: .high, sizing: .quality(.high), subtitleCues: nil, subtitlesSkippedReason: nil,
            normalizeLoudness: false, projectFingerprint: nil)
        _ = try await FinalExport.run(job, to: url, progress: { _ in })
    }

    private func compositedFrame(
        _ asset: AVAsset, _ videoComposition: AVVideoComposition, at seconds: Double
    ) async throws -> CVPixelBuffer {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: try await asset.loadTracks(withMediaType: .video),
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = videoComposition
        reader.add(output)
        #expect(reader.startReading())
        defer { reader.cancelReading() }
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetPresentationTimeStamp(sample).seconds >= seconds - 0.001 else { continue }
            return try #require(CMSampleBufferGetImageBuffer(sample))
        }
        throw CocoaError(.fileReadCorruptFile)
    }

    private func decodedFrame(_ url: URL, at seconds: Double) async throws -> CVPixelBuffer {
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: try #require(try await asset.loadTracks(withMediaType: .video).first),
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: seconds, preferredTimescale: 600), duration: CMTime(value: 1, timescale: 10))
        #expect(reader.startReading())
        defer { reader.cancelReading() }
        let sample = try #require(output.copyNextSampleBuffer())
        return try #require(CMSampleBufferGetImageBuffer(sample))
    }

    /// Зелёный канал пикселя; -1 — точка за пределами кадра.
    private func luma(_ buffer: CVPixelBuffer, _ x: Int, _ y: Int) -> Int {
        guard x < CVPixelBufferGetWidth(buffer), y < CVPixelBufferGetHeight(buffer) else { return -1 }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return -1 }
        return Int(base[y * CVPixelBufferGetBytesPerRow(buffer) + x * 4 + 1])
    }

    private func near(_ value: Int, _ expected: UInt8) -> Bool { abs(value - Int(expected)) <= 24 }

    @Test("landscape then portrait: the portrait piece stands upright between black side bars")
    func landscapeThenPortrait() async throws {
        let scene = try await scene()
        defer { scene.remove() }
        let result = await render([scene.landscape, scene.portrait], root: scene.root)
        let file = scene.root.appendingPathComponent("out.mp4")
        try await export(result, to: file)
        let preview = try await previewComposition(result)
        #expect(preview.renderSize == CGSize(width: 320, height: 180))

        for (label, frame) in [
            ("preview", { try await compositedFrame(result.composition, preview, at: $0) }),
            ("mp4", { try await decodedFrame(file, at: $0) }),
        ] as [(String, (Double) async throws -> CVPixelBuffer)] {
            let first = try await frame(0.5)
            #expect(near(luma(first, 20, 90), Self.gray), "\(label): горизонтальный кусок во весь кадр")
            let second = try await frame(1.5)
            #expect(near(luma(second, 160, 40), Self.bright), "\(label): светлый верх — кусок стоит, а не лежит")
            #expect(near(luma(second, 160, 140), Self.dark), "\(label): тёмный низ")
            #expect((0..<30).contains(luma(second, 20, 90)), "\(label): слева чёрное поле, а не растянутый кадр")
            #expect((0..<30).contains(luma(second, 300, 90)), "\(label): справа чёрное поле")
        }
    }

    @Test("portrait then landscape: the canvas is vertical and the landscape piece sits between black bars")
    func portraitThenLandscape() async throws {
        let scene = try await scene()
        defer { scene.remove() }
        let result = await render([scene.portrait, scene.landscape], root: scene.root)
        let file = scene.root.appendingPathComponent("out.mp4")
        try await export(result, to: file)
        let preview = try await previewComposition(result)
        #expect(preview.renderSize == CGSize(width: 180, height: 320))

        for (label, frame) in [
            ("preview", { try await compositedFrame(result.composition, preview, at: $0) }),
            ("mp4", { try await decodedFrame(file, at: $0) }),
        ] as [(String, (Double) async throws -> CVPixelBuffer)] {
            let first = try await frame(0.5)
            #expect(near(luma(first, 90, 60), Self.bright), "\(label): вертикальный кусок стоит")
            #expect(near(luma(first, 90, 260), Self.dark), "\(label)")
            let second = try await frame(1.5)
            #expect(near(luma(second, 90, 160), Self.gray), "\(label): горизонтальный кусок в середине")
            #expect((0..<30).contains(luma(second, 90, 20)), "\(label): сверху чёрное поле")
            #expect((0..<30).contains(luma(second, 90, 300)), "\(label): снизу чёрное поле")
        }
    }

    /// Как повёрнут второй кусок и где после поворота окажется его светлая (левая) половина.
    enum Turn: String, CaseIterable, Sendable {
        case upsideDown, mirrored, counterClockwise

        var transform: CGAffineTransform {
            switch self {
            case .upsideDown: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 320, ty: 180)
            case .mirrored: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 320, ty: 0)
            case .counterClockwise: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 320)
            }
        }

        /// Точка светлой половины и точка тёмной в кадре 320×180 ролика.
        var probes: (bright: (Int, Int), dark: (Int, Int)) {
            switch self {
            case .upsideDown, .mirrored: ((240, 90), (80, 90))
            case .counterClockwise: ((160, 140), (160, 40))
            }
        }
    }

    @Test("a piece turned 180°, mirrored or 270° after a plain one keeps its own orientation", arguments: Turn.allCases)
    func turnedPiece(turn: Turn) async throws {
        let scene = try await scene()
        defer { scene.remove() }
        let turned = scene.root.appendingPathComponent("turned.mov")
        try await still(to: turned, transform: turn.transform) { $0 < 160 ? Self.bright : Self.dark }
        let result = await render([scene.landscape, turned], root: scene.root)
        let file = scene.root.appendingPathComponent("out.mp4")
        try await export(result, to: file)

        let frame = try await decodedFrame(file, at: 1.5)
        let (bright, dark) = turn.probes
        #expect(near(luma(frame, bright.0, bright.1), Self.bright), "\(turn): светлая половина на своём месте")
        #expect(near(luma(frame, dark.0, dark.1), Self.dark), "\(turn)")
        #expect(near(luma(try await decodedFrame(file, at: 0.5), 20, 90), Self.gray), "первый кусок как был")
    }

    @Test("one geometry for the whole timeline keeps the plain path without a picture of its own")
    func uniformGeometryStaysPlain() async throws {
        let scene = try await scene()
        defer { scene.remove() }
        let result = await render([scene.landscape, scene.landscape], root: scene.root)
        #expect(result.videoPlan == nil)
    }
}
