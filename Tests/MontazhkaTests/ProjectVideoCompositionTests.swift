@preconcurrency import AVFoundation
import CoreVideo
import Foundation
import Testing

@testable import MontazhkaKit

/// Картинка обычного проекта: анимация HyperFrames поверх ленты видна только в своём окне,
/// ложится в кадр как задумано и в предпросмотре, и в готовом MP4.
@Suite("Project picture: overlays and burned subtitles")
struct ProjectVideoCompositionTests {
    private struct RGB: CustomStringConvertible {
        let r: Int
        let g: Int
        let b: Int

        var description: String { "(\(r), \(g), \(b))" }

        func isClose(to other: RGB, within tolerance: Int) -> Bool {
            abs(r - other.r) <= tolerance && abs(g - other.g) <= tolerance && abs(b - other.b) <= tolerance
        }

        static let gray = RGB(r: 128, g: 128, b: 128)
        static let red = RGB(r: 255, g: 0, b: 0)
        /// Белый с альфой 0,5 поверх серого 128: 128 + 127 × 0,5 ≈ 191.
        static let band = RGB(r: 191, g: 191, b: 191)
    }

    /// Серая лента 3 с (320×180) и анимация 1 с того же размера на 1,0–2,0 с ленты.
    private struct Scene {
        let root: URL
        let base: MediaReference
        let overlayURL: URL
        var project: Project

        static let width = 320
        static let height = 180

        static func make(position: OverlayPosition = .full) async throws -> Scene {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("montazhka-picture-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let video = root.appendingPathComponent("base.mov")
            try await TestVideoFactory.make(segments: [(duration: 3, loud: true)], videoLuma: 128, to: video)
            let overlayURL = root.appendingPathComponent("overlay.mov")
            try await TestOverlayFactory.make(width: width, height: height, duration: 1, to: overlayURL)
            let base = MediaReference(url: video)
            var project = Project(name: "Анимация", clips: [Clip(source: base, start: 0, end: 3)])
            project.overlays = [overlay(url: overlayURL, anchor: base.id, at: 1, position: position)]
            return Scene(root: root, base: base, overlayURL: overlayURL, project: project)
        }

        static func overlay(
            url: URL, anchor: UUID, at time: Double, position: OverlayPosition = .full, scale: Double = 1
        ) -> ProjectOverlay {
            ProjectOverlay(
                id: UUID(), media: MediaReference(url: url),
                anchor: OverlayAnchor(sourceID: anchor, sourceTime: time, wordText: "слово"),
                align: .start, payoffAt: 0, duration: 1, position: position, scale: scale)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        var pipeline: MediaPipeline {
            MediaPipeline(
                voiceStore: VoiceEnhanceStore(cacheDir: root.appendingPathComponent("voice")),
                musicEQStore: MusicEQStore(cacheDir: root.appendingPathComponent("eq")))
        }
    }

    // MARK: - Чтение кадров

    private struct ReadFailure: Error {
        let reason: String
    }

    /// Кадр ленты через видеокомпозицию — ровно так, как его читает экспорт: подряд
    /// с начала. Чтение с середины не видит залипший последний кадр анимации.
    private func compositedFrame(
        _ asset: AVAsset, _ videoComposition: AVVideoComposition, at seconds: Double
    ) async throws -> CVPixelBuffer {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: try await asset.loadTracks(withMediaType: .video),
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = videoComposition
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ReadFailure(reason: "composition read") }
        defer { reader.cancelReading() }
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetPresentationTimeStamp(sample).seconds >= seconds - 0.001 else { continue }
            return try #require(CMSampleBufferGetImageBuffer(sample))
        }
        throw ReadFailure(reason: "no frame at \(seconds) s")
    }

    /// Кадр готового файла, раскодированный как есть.
    private func decodedFrame(_ url: URL, at seconds: Double) async throws -> CVPixelBuffer {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: seconds, preferredTimescale: 600), duration: CMTime(value: 1, timescale: 10))
        guard reader.startReading() else { throw reader.error ?? ReadFailure(reason: "file read") }
        defer { reader.cancelReading() }
        let sample = try #require(output.copyNextSampleBuffer())
        return try #require(CMSampleBufferGetImageBuffer(sample))
    }

    private func pixel(_ buffer: CVPixelBuffer, _ point: CGPoint) -> RGB {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else {
            return RGB(r: -1, g: -1, b: -1)
        }
        let at = base + Int(point.y) * CVPixelBufferGetBytesPerRow(buffer) + Int(point.x) * 4
        return RGB(r: Int(at[2]), g: Int(at[1]), b: Int(at[0]))
    }

    /// До окна — серо, в окне — красный квадрат и полупрозрачная полоса, после окна —
    /// снова серо: последний кадр анимации не залипает.
    private func expectOverlayOnlyInWindow(
        _ frame: (Double) async throws -> CVPixelBuffer, label: String
    ) async throws {
        let points = TestOverlayFactory.probes(width: Scene.width, height: Scene.height)
        for time in [0.5, 2.5] {
            let buffer = try await frame(time)
            let centre = pixel(buffer, points.centre)
            let band = pixel(buffer, points.band)
            #expect(centre.isClose(to: .gray, within: 8), "\(label) \(time) s centre \(centre)")
            #expect(band.isClose(to: .gray, within: 8), "\(label) \(time) s band \(band)")
        }
        let inside = try await frame(1.5)
        let centre = pixel(inside, points.centre)
        let band = pixel(inside, points.band)
        let corner = pixel(inside, points.corner)
        #expect(centre.isClose(to: .red, within: 20), "\(label) 1.5 s centre \(centre)")
        #expect(band.isClose(to: .band, within: 25), "\(label) 1.5 s band \(band)")
        #expect(corner.isClose(to: .gray, within: 8), "\(label) 1.5 s corner \(corner)")
    }

    // MARK: - Анимация в кадре

    @Test("the window picture shows the animation only inside its window")
    func overlayInFrameComposition() async throws {
        let scene = try await Scene.make()
        defer { scene.remove() }

        let result = await scene.pipeline.render(
            MediaRenderRequest(project: scene.project, mode: .preview, readyEnhancedAudio: [:]))

        #expect(result.warnings.isEmpty, "\(result.warnings.map(\.message))")
        let plan = try #require(result.videoPlan)
        #expect(plan.frameComposition.renderSize == CGSize(width: Scene.width, height: Scene.height))
        #expect(plan.frameComposition.animationTool == nil)
        try await expectOverlayOnlyInWindow(
            { try await compositedFrame(result.composition, plan.frameComposition, at: $0) }, label: "frame")
    }

    @Test("the exported MP4 shows the animation only inside its window")
    func overlayInExportedFile() async throws {
        let scene = try await Scene.make()
        defer { scene.remove() }
        let service = AgentService(baseDirectory: scene.root)
        try await service.store.save(scene.project)
        let output = scene.root.appendingPathComponent("out.mp4")

        let response = await service.export(
            projectID: scene.project.id, outputPath: output.path, quality: "compact",
            final: false, confirmFinal: false, overwrite: false)

        #expect(response.ok, "\(String(describing: response.error))")
        try await expectOverlayOnlyInWindow({ try await decodedFrame(output, at: $0) }, label: "mp4")
    }

    /// Вшитые субтитры идут через Core Animation и сессию экспорта. Кадр, который ничего
    /// не смешивает (одна основа как есть), сессия пропускает мимо смешивания, и слой
    /// Core Animation выходит белым. Текст в `swift test` не рисуется, а основа — видна.
    @Test("burning subtitles keeps the picture: the MP4 is not white outside phrases and animations")
    func burnedExportKeepsThePicture() async throws {
        let scene = try await Scene.make()
        defer { scene.remove() }
        let service = AgentService(baseDirectory: scene.root)
        try await service.store.save(scene.project)
        _ = try await cacheTranscript(for: scene, store: service.store)
        let output = scene.root.appendingPathComponent("burned.mp4")

        let response = await service.export(
            projectID: scene.project.id, outputPath: output.path, quality: "compact",
            final: false, confirmFinal: false, overwrite: false, burnSubtitles: true)

        #expect(response.ok, "\(String(describing: response.error))")
        let points = TestOverlayFactory.probes(width: Scene.width, height: Scene.height)
        // Во время фразы верх кадра — основа: текст внизу.
        let phrase = pixel(try await decodedFrame(output, at: 0.8), CGPoint(x: 20, y: 20))
        #expect(phrase.isClose(to: .gray, within: 8), "0.8 s top \(phrase)")
        try await expectOverlayOnlyInWindow({ try await decodedFrame(output, at: $0) }, label: "burned mp4")
        let inside = try await decodedFrame(output, at: 1.5)
        #expect(pixel(inside, points.corner).isClose(to: .gray, within: 8))
    }

    /// Время показа каждого кадра файла, без декодирования.
    private func frameTimes(_ url: URL) async throws -> [Double] {
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: try #require(try await asset.loadTracks(withMediaType: .video).first), outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ReadFailure(reason: "frame times") }
        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
        }
        return times.sorted()
    }

    /// Ролик 29,97 к/с (шаг 1001/30000), 10 с, серый, с пометками цвета BT.709, без звука.
    private func writeNTSCBase(to url: URL) async throws {
        let frame = try TestOverlayFactory.pixelBuffer(width: 320, height: 180, format: kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(frame, [])
        if let base = CVPixelBufferGetBaseAddress(frame) {
            memset(base, 128, CVPixelBufferGetDataSize(frame))
        }
        CVPixelBufferUnlockBaseAddress(frame, [])
        try await TestOverlayFactory.writeStill(
            frame,
            settings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180,
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
            ],
            fileType: .mov, frameCount: 300, frameDuration: CMTime(value: 1001, timescale: 30000), to: url)
    }

    private func export(
        _ rendered: MediaRenderResult, videoComposition: AVVideoComposition?, to url: URL
    ) async throws {
        let job = FinalExportJob(
            input: ExportInput(
                composition: rendered.composition, audioMix: rendered.audioMix, videoComposition: videoComposition),
            quality: .compact, sizing: .quality(.compact), subtitleCues: nil, subtitlesSkippedReason: nil,
            normalizeLoudness: false, projectFingerprint: nil)
        _ = try await FinalExport.run(job, to: url, progress: { _ in })
    }

    /// Анимация не меняет ни шаг кадров ролика, ни его цвет: 29,97 к/с не пересчитываются
    /// в 30 (иначе раз в ~33 с кадр повторяется), цвет — как у обычного экспорта.
    @Test("an animation keeps the plain export's frame cadence and colour handling")
    func cadenceAndColourMatchPlainExport() async throws {
        let scene = try await Scene.make()
        defer { scene.remove() }
        let base = scene.root.appendingPathComponent("ntsc.mov")
        try await writeNTSCBase(to: base)
        let media = MediaReference(url: base)
        var project = Project(name: "29,97", clips: [Clip(source: media, start: 0, end: 10)])
        let plain = await scene.pipeline.render(
            MediaRenderRequest(project: project, mode: .export, readyEnhancedAudio: [:]))
        project.overlays = [Scene.overlay(url: scene.overlayURL, anchor: media.id, at: 1)]
        let animated = await scene.pipeline.render(
            MediaRenderRequest(project: project, mode: .export, readyEnhancedAudio: [:]))

        let reference = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: plain.composition)
        let plan = try #require(animated.videoPlan)
        for composition in [plan.frameComposition, plan.exportComposition] {
            #expect(composition.frameDuration == reference.frameDuration, "\(composition.frameDuration)")
            #expect(composition.colorPrimaries == reference.colorPrimaries)
            #expect(composition.colorTransferFunction == reference.colorTransferFunction)
            #expect(composition.colorYCbCrMatrix == reference.colorYCbCrMatrix)
        }

        let plainFile = scene.root.appendingPathComponent("plain.mp4")
        let animatedFile = scene.root.appendingPathComponent("animated.mp4")
        try await export(plain, videoComposition: nil, to: plainFile)
        try await export(animated, videoComposition: plan.exportComposition, to: animatedFile)
        let plainTimes = try await frameTimes(plainFile)
        let animatedTimes = try await frameTimes(animatedFile)
        #expect(plainTimes.count == 300)
        #expect(animatedTimes.count == plainTimes.count, "\(animatedTimes.count) frames vs \(plainTimes.count)")
        // MP4 хранит время кадров с шагом 1/600 с: кадр ровно на половине шага два пути могут
        // округлить в соседние стороны. Пересчёт в 30 к/с расходится на 10+ мс к концу.
        let drift = zip(plainTimes, animatedTimes).map { abs($0 - $1) }.max() ?? .infinity
        #expect(drift <= 1.0 / 600 + 0.0001, "largest frame time difference \(drift) s")
        let plainLength = try await AVURLAsset(url: plainFile).load(.duration).seconds
        let animatedLength = try await AVURLAsset(url: animatedFile).load(.duration).seconds
        #expect(abs(plainLength - animatedLength) < 0.001, "\(animatedLength) s vs \(plainLength) s")
    }

    /// Вертикальный ролик: кадр лежит на боку, поворот — в дорожке, и без сдвига (так пишут
    /// не все камеры, но бывает). Метка в левом верхнем углу лежащего кадра после поворота
    /// стоит справа сверху, а кадр целиком внутри холста.
    @Test("a rotated base renders upright and the animation fits the upright frame")
    func rotatedBase() async throws {
        let scene = try await Scene.make()
        defer { scene.remove() }
        let base = scene.root.appendingPathComponent("portrait.mov")
        try await writeMarkedBase(to: base, transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0))
        let overlayURL = scene.root.appendingPathComponent("portrait-overlay.mov")
        try await TestOverlayFactory.make(width: 90, height: 160, duration: 1, to: overlayURL)
        let media = MediaReference(url: base)
        var project = Project(name: "Вертикаль", clips: [Clip(source: media, start: 0, end: 3)])
        project.overlays = [Scene.overlay(url: overlayURL, anchor: media.id, at: 1)]

        let result = await scene.pipeline.render(
            MediaRenderRequest(project: project, mode: .preview, readyEnhancedAudio: [:]))

        let plan = try #require(result.videoPlan)
        #expect(plan.frameComposition.renderSize == CGSize(width: 180, height: 320))
        let before = try await compositedFrame(result.composition, plan.frameComposition, at: 0.5)
        let marker = pixel(before, CGPoint(x: 160, y: 20))
        #expect(marker.isClose(to: RGB(r: 255, g: 255, b: 255), within: 12), "marker \(marker)")
        for point in [CGPoint(x: 20, y: 20), CGPoint(x: 20, y: 300), CGPoint(x: 170, y: 310)] {
            #expect(pixel(before, point).isClose(to: .gray, within: 8), "\(point) \(pixel(before, point))")
        }
        // Анимация 90×160 вписана в кадр 180×320 целиком: все её точки вдвое дальше от угла.
        let inside = try await compositedFrame(result.composition, plan.frameComposition, at: 1.5)
        let points = TestOverlayFactory.probes(width: 90, height: 160)
        let centre = pixel(inside, CGPoint(x: points.centre.x * 2, y: points.centre.y * 2))
        let band = pixel(inside, CGPoint(x: points.band.x * 2, y: points.band.y * 2))
        let corner = pixel(inside, CGPoint(x: points.corner.x * 2, y: points.corner.y * 2))
        #expect(centre.isClose(to: .red, within: 20), "centre \(centre)")
        #expect(band.isClose(to: .band, within: 25), "band \(band)")
        #expect(corner.isClose(to: .gray, within: 8), "corner \(corner)")
    }

    /// Серый кадр 320×180 с белой меткой 40×40 в левом верхнем углу, 3 с, без звука.
    private func writeMarkedBase(to url: URL, transform: CGAffineTransform) async throws {
        let frame = try TestOverlayFactory.pixelBuffer(width: 320, height: 180, format: kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(frame, [])
        if let base = CVPixelBufferGetBaseAddress(frame) {
            let rowBytes = CVPixelBufferGetBytesPerRow(frame)
            for y in 0..<180 {
                let row = (base + y * rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<320 {
                    let value: UInt8 = x < 40 && y < 40 ? 255 : 128
                    (row[x * 4], row[x * 4 + 1], row[x * 4 + 2], row[x * 4 + 3]) = (value, value, value, 255)
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(frame, [])
        try await TestOverlayFactory.writeStill(
            frame, settings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180],
            fileType: .mov, frameCount: 30, frameDuration: CMTime(value: 1, timescale: 10), transform: transform,
            to: url)
    }

    struct Placement: Sendable, CustomTestStringConvertible {
        let position: OverlayPosition
        let scale: Double
        let natural: CGSize
        let transform: CGAffineTransform
        let expected: CGRect

        var testDescription: String { "\(position) ×\(scale) \(natural)" }
    }

    static let placements: [Placement] = [
        // Во весь кадр масштаб не действует.
        Placement(
            position: .full, scale: 0.5, natural: CGSize(width: 320, height: 180), transform: .identity,
            expected: CGRect(x: 0, y: 0, width: 320, height: 180)),
        Placement(
            position: .full, scale: 1, natural: CGSize(width: 100, height: 100), transform: .identity,
            expected: CGRect(x: 70, y: 0, width: 180, height: 180)),
        Placement(
            position: .center, scale: 0.5, natural: CGSize(width: 320, height: 180), transform: .identity,
            expected: CGRect(x: 80, y: 45, width: 160, height: 90)),
        // Отступ в углу — 4 % ширины (12,8) и высоты (7,2) кадра.
        Placement(
            position: .topRight, scale: 0.5, natural: CGSize(width: 320, height: 180), transform: .identity,
            expected: CGRect(x: 147.2, y: 7.2, width: 160, height: 90)),
        Placement(
            position: .bottomLeft, scale: 0.25, natural: CGSize(width: 320, height: 180), transform: .identity,
            expected: CGRect(x: 12.8, y: 127.8, width: 80, height: 45)),
        Placement(
            position: .topLeft, scale: 0.25, natural: CGSize(width: 320, height: 180), transform: .identity,
            expected: CGRect(x: 12.8, y: 7.2, width: 80, height: 45)),
        Placement(
            position: .bottomRight, scale: 0.25, natural: CGSize(width: 320, height: 180), transform: .identity,
            expected: CGRect(x: 227.2, y: 127.8, width: 80, height: 45)),
        // Анимация с поворотом в дорожке ставится по своему видимому кадру.
        Placement(
            position: .full, scale: 1, natural: CGSize(width: 180, height: 320),
            transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 320, ty: 0),
            expected: CGRect(x: 0, y: 0, width: 320, height: 180)),
    ]

    @Test("an animation is placed by its position and scale", arguments: placements)
    func placement(_ placement: Placement) {
        let transform = ProjectVideoComposition.overlayTransform(
            naturalSize: placement.natural, preferredTransform: placement.transform, position: placement.position,
            scale: placement.scale, renderSize: CGSize(width: 320, height: 180))
        let rect = CGRect(origin: .zero, size: placement.natural).applying(transform)
        for (actual, expected) in [
            (rect.minX, placement.expected.minX), (rect.minY, placement.expected.minY),
            (rect.width, placement.expected.width), (rect.height, placement.expected.height),
        ] {
            #expect(abs(actual - expected) < 0.01, "\(rect) vs \(placement.expected)")
        }
    }

    // MARK: - Дорожки и план

    @Test("the base stays the first video track and each animation gets its own track after it")
    func trackOrder() async throws {
        let scene = try await Scene.make()
        defer { scene.remove() }

        let result = await scene.pipeline.render(
            MediaRenderRequest(project: scene.project, mode: .export, readyEnhancedAudio: [:]))

        let tracks = try await result.composition.loadTracks(withMediaType: .video)
        #expect(tracks.count == 2)
        let base = try #require(tracks.first as? AVCompositionTrack)
        let overlay = try #require(tracks.last as? AVCompositionTrack)
        let whole = try #require(base.segments.first?.timeMapping.target)
        #expect(base.segments.count == 1 && abs(whole.start.seconds) < 0.001 && abs(whole.end.seconds - 3) < 0.001)
        let shown = try #require(overlay.segments.last?.timeMapping.target)
        #expect(abs(shown.start.seconds - 1) < 0.001 && abs(shown.end.seconds - 2) < 0.001, "\(shown)")
        // Размер готового файла по-прежнему считается от основной дорожки.
        let settings = try await Transcoder.settings(
            for: .compact, input: ExportInput(composition: result.composition, audioMix: nil))
        #expect(settings.dimensions == CGSize(width: 320, height: 180))
    }

    @Test("nothing to draw means no own picture: export and preview stay as before")
    func noPlanWithoutOverlaysOrSubtitles() async throws {
        var scene = try await Scene.make()
        defer { scene.remove() }
        let pipeline = scene.pipeline

        var plain = scene.project
        plain.overlays = []
        let untouched = await pipeline.render(
            MediaRenderRequest(project: plain, mode: .export, readyEnhancedAudio: [:]))
        #expect(untouched.videoPlan == nil)
        #expect(try await untouched.composition.loadTracks(withMediaType: .video).count == 1)

        // Слово-якорь вырезано: анимацию не видно, дорожки и предупреждения нет.
        scene.project.clips = [Clip(source: scene.base, start: 1.5, end: 3)]
        let cut = await pipeline.render(
            MediaRenderRequest(project: scene.project, mode: .export, readyEnhancedAudio: [:]))
        #expect(cut.videoPlan == nil)
        #expect(cut.warnings.isEmpty)
        #expect(try await cut.composition.loadTracks(withMediaType: .video).count == 1)

        // Файл анимации пропал: ролик собирается без неё и говорит об этом.
        scene.project.clips = [Clip(source: scene.base, start: 0, end: 3)]
        try FileManager.default.removeItem(at: scene.overlayURL)
        let missing = await pipeline.render(
            MediaRenderRequest(project: scene.project, mode: .export, readyEnhancedAudio: [:]))
        #expect(missing.videoPlan == nil)
        #expect(missing.warnings == [.overlayUnavailable("overlay.mov")])
        #expect(try await missing.composition.loadTracks(withMediaType: .video).count == 1)
    }

    @Test("burned subtitles go into the export only; frames get them as a still")
    func subtitlesOnlyPlan() async throws {
        var scene = try await Scene.make()
        defer { scene.remove() }
        scene.project.overlays = []
        let cue = ShortsSubtitleCue(
            words: [ShortsSubtitleWord(text: "Привет", start: 0.5, end: 1.4)], start: 0.5, end: 1.4)
        let layer = ProjectSubtitleLayer(cues: [cue], appearance: .default, highlight: false)

        let result = await scene.pipeline.render(
            MediaRenderRequest(project: scene.project, mode: .export, readyEnhancedAudio: [:], subtitleLayer: layer))

        let plan = try #require(result.videoPlan)
        #expect(plan.frameComposition.animationTool == nil)
        #expect(plan.exportComposition.animationTool != nil)
        #expect(plan.exportComposition.renderSize == CGSize(width: Scene.width, height: Scene.height))
        let still = try #require(plan.overlayImageAt?(1))
        #expect(still.width == Scene.width && still.height == Scene.height)
        // Сам кадр без субтитров — основа, как на ленте.
        let frame = try await compositedFrame(result.composition, plan.frameComposition, at: 1)
        #expect(pixel(frame, CGPoint(x: 160, y: 90)).isClose(to: .gray, within: 8))

        // У черновика шортса своя картинка: ни анимаций, ни этого слоя.
        var draft = scene.project
        draft.overlays = [Scene.overlay(url: scene.overlayURL, anchor: scene.base.id, at: 1)]
        draft.shorts = ShortsPresentation(
            title: "Шортс", reason: "", layout: .fit, resolvedLayout: .fit, hook: nil, subtitles: nil, zooms: [],
            exportPath: nil)
        let shorts = await scene.pipeline.render(
            MediaRenderRequest(project: draft, mode: .export, readyEnhancedAudio: [:], subtitleLayer: layer))
        #expect(shorts.videoPlan == nil)
        #expect(try await shorts.composition.loadTracks(withMediaType: .video).count == 1)
    }

    // MARK: - Окно и кадры агента

    /// Расшифровка в кэше: «Привет это проверка» звучит 0,2–1,4 с.
    private func cacheTranscript(for scene: Scene, store: ProjectStore) async throws -> [TranscriptWord] {
        let words = [
            TranscriptWord(sourceID: scene.base.id, text: "Привет", start: 0.2, end: 0.5, confidence: 1),
            TranscriptWord(sourceID: scene.base.id, text: "это", start: 0.6, end: 0.8, confidence: 1),
            TranscriptWord(sourceID: scene.base.id, text: "проверка", start: 0.9, end: 1.4, confidence: 1),
        ]
        let cacheURL = await TranscriptStore(cacheDir: store.transcriptsDir, modelsDir: store.modelsDir)
            .cacheURL(for: scene.base)
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(TranscriptDocument(words: words)).write(to: cacheURL)
        return words
    }

    @MainActor
    private func waitForPreview(_ controller: EditorController) async throws {
        for _ in 0..<500 where controller.previewState != .ready {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.previewState == .ready)
    }

    @MainActor
    @Test("the window previews animations and exports them with burned subtitles when asked")
    func windowPreviewAndExport() async throws {
        var scene = try await Scene.make()
        defer { scene.remove() }
        scene.project.export.burnSubtitles = true
        let store = ProjectStore(baseDirectory: scene.root)
        try await store.save(scene.project)
        _ = try await cacheTranscript(for: scene, store: store)
        let controller = EditorController(
            project: scene.project, store: store, openRouterKeyStore: EmptyOpenRouterKeyStore())

        try await waitForPreview(controller)
        let preview = try #require(controller.player.currentItem?.videoComposition)
        #expect(preview.renderSize == CGSize(width: Scene.width, height: Scene.height))
        #expect(preview.animationTool == nil)

        let burned = try await controller.prepareExport(step: { _ in })
        #expect(burned.videoComposition?.animationTool != nil)
        #expect(burned.sizing == .quality)
        #expect(burned.subtitleCues?.map(\.text) == ["Привет это проверка"])

        controller.setExportPreferences(ExportPreferences(normalizeLoudness: true, burnSubtitles: false))
        let overlayOnly = try await controller.prepareExport(step: { _ in })
        #expect(overlayOnly.videoComposition != nil)
        #expect(overlayOnly.videoComposition?.animationTool == nil)

        controller.removeOverlay(id: try #require(scene.project.overlays.first?.id))
        try await waitForPreview(controller)
        #expect(controller.player.currentItem?.videoComposition == nil)
        let plain = try await controller.prepareExport(step: { _ in })
        #expect(plain.videoComposition == nil)
        await controller.shutdown()
    }

    /// Вызов из изоляции актора (как у AgentService): план кадров переходит границу актора.
    @MainActor
    @Test("frames of a normal project show animations and, when burned, subtitle stills")
    func framePlanShowsThePicture() async throws {
        var scene = try await Scene.make()
        defer { scene.remove() }
        let store = ProjectStore(baseDirectory: scene.root)
        let words = try await cacheTranscript(for: scene, store: store)
        let mapped = TranscriptTimelineMapper.make(clips: scene.project.clips, transcripts: words).words
        let pipeline = scene.pipeline

        let plain = try await pipeline.framePlan(for: scene.project, words: mapped)
        #expect(plain.overlayAt == nil)
        let composition = try #require(plain.videoComposition)
        let frame = try await compositedFrame(plain.asset, composition, at: 1.5)
        #expect(pixel(frame, CGPoint(x: 160, y: 90)).isClose(to: .red, within: 20))

        scene.project.export.burnSubtitles = true
        let burned = try await pipeline.framePlan(for: scene.project, words: mapped)
        #expect(burned.videoComposition?.animationTool == nil)
        let still = try #require(burned.overlayAt?(1))
        #expect(still.width == Scene.width && still.height == Scene.height)

        scene.project.overlays = []
        let noWords = try await pipeline.framePlan(for: scene.project, words: nil)
        #expect(noWords.videoComposition == nil)
        #expect(noWords.overlayAt == nil)
    }
}
