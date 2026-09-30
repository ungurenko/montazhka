@preconcurrency import AVFoundation
import CoreVideo
import Foundation
import Testing
import os

@testable import MontazhkaKit

/// Анимация из HyperFrames приходит с прямой (straight) альфой и цветом, закодированным
/// по BT.601, а стандартный компоновщик AVFoundation считает альфу premultiplied.
/// После подготовки картинка поверх видео должна выглядеть как задумано: красный —
/// красным, полупрозрачная белая полоса — серединой между белым и фоном.
@Suite("Overlay media normalizer")
struct OverlayMediaNormalizerTests {
    /// Матрица, которой тест сам переводит RGB в YCbCr.
    enum Matrix: Sendable {
        case bt601, bt709

        var coefficients: (kr: Double, kb: Double) {
            switch self {
            case .bt601: (0.299, 0.114)
            case .bt709: (0.2126, 0.0722)
            }
        }

        var tag: String {
            switch self {
            case .bt601: AVVideoYCbCrMatrix_ITU_R_601_4
            case .bt709: AVVideoYCbCrMatrix_ITU_R_709_2
            }
        }
    }

    /// Каким записан исходный файл анимации.
    struct Source: Sendable, CustomTestStringConvertible {
        let name: String
        let matrix: Matrix
        /// false — без цветовых пометок, как пишет HyperFrames.
        let tagged: Bool
        let premultiplied: Bool
        var width = 128
        var height = 128

        var testDescription: String { name }
    }

    static let sources = [
        Source(name: "straight alpha, tagged BT.601", matrix: .bt601, tagged: true, premultiplied: false),
        Source(name: "straight alpha, tagged BT.709", matrix: .bt709, tagged: true, premultiplied: false),
        Source(name: "already premultiplied", matrix: .bt709, tagged: true, premultiplied: true),
        // Без пометок AVFoundation сама угадывает матрицу: до 720 px в ширину — BT.601,
        // от 720 px — BT.709 (как для кадра 1920×1080 из HyperFrames). Ширина 720 нужна,
        // чтобы случай ловил ошибку: при угадывании BT.709 красный вышел бы (255,25,0).
        Source(
            name: "untagged, BT.601 like HyperFrames", matrix: .bt601, tagged: false, premultiplied: false,
            width: 720, height: 128),
    ]

    private static let fps: Int32 = 30
    private static let frameCount = 30
    private static let bandAlpha: UInt8 = 128
    private static let gray: UInt8 = 0x80

    private struct Failure: Error {
        let reason: String
    }

    private struct RGB {
        let r: Int
        let g: Int
        let b: Int
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-normalize-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Сцена

    /// Прямая (straight) альфа 0…255 и цвет 0…1: прозрачный фон, непрозрачный красный
    /// квадрат в центре, белая полоса с альфой 0,5 в верхней четверти.
    private static func straightPixel(x: Int, y: Int, width: Int, height: Int) -> (rgb: [Double], alpha: UInt8) {
        let half = max(4, height / 8)
        if abs(x - width / 2) < half, abs(y - height / 2) < half { return ([1, 0, 0], 255) }
        if y < height / 4 { return ([1, 1, 1], bandAlpha) }
        return ([0, 0, 0], 0)
    }

    /// Точки проверки: центр квадрата, середина полосы, прозрачный угол.
    private static func probes(width: Int, height: Int) -> (centre: (Int, Int), band: (Int, Int), corner: (Int, Int)) {
        ((width / 2, height / 2), (width / 8, height / 8), (width - 4, height - 4))
    }

    // MARK: - Запись входных файлов

    /// Пишет видео из одинаковых кадров через `requestMediaDataWhenReady`: ручной опрос
    /// `isReadyForMoreMediaData` в тестах может повиснуть.
    private func writeVideo(
        to url: URL, fileType: AVFileType, settings: [String: Any], frame: CVPixelBuffer
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? Failure(reason: "start") }
        writer.startSession(atSourceTime: .zero)

        let feed = FeedIO(input: input, adaptor: adaptor, frame: frame)
        let fed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let queue = DispatchQueue(label: "normalizer-test.feed")
            let state = FeedState()
            queue.asyncAfter(deadline: .now() + .seconds(30)) {
                guard !state.done else { return }
                state.done = true
                continuation.resume(returning: false)
            }
            feed.input.requestMediaDataWhenReady(on: queue) {
                while feed.input.isReadyForMoreMediaData, !state.done {
                    guard state.index < Self.frameCount else {
                        state.done = true
                        feed.input.markAsFinished()
                        continuation.resume(returning: true)
                        return
                    }
                    let time = CMTime(value: CMTimeValue(state.index), timescale: Self.fps)
                    guard feed.adaptor.append(feed.frame, withPresentationTime: time) else {
                        state.done = true
                        continuation.resume(returning: false)
                        return
                    }
                    state.index += 1
                }
            }
        }
        guard fed else {
            writer.cancelWriting()
            throw Failure(reason: "writer stalled or refused a frame: \(String(describing: writer.error))")
        }
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(Self.frameCount), timescale: Self.fps))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? Failure(reason: "finish") }
    }

    private struct FeedIO: @unchecked Sendable {
        let input: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let frame: CVPixelBuffer
    }

    private final class FeedState: @unchecked Sendable {
        var index = 0
        var done = false
    }

    private func makeBuffer(width: Int, height: Int, format: OSType) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        CVPixelBufferCreate(nil, width, height, format, attributes, &created)
        guard let buffer = created else { throw Failure(reason: "pixel buffer") }
        return buffer
    }

    /// Кадр в YCbCr 4:4:4 с альфой (y416, limited-диапазон), посчитанный вручную:
    /// писатель AVFoundation из BGRA всегда кодирует по BT.709, какую бы матрицу ни просили.
    private func overlayFrame(_ source: Source) throws -> CVPixelBuffer {
        let buffer = try makeBuffer(
            width: source.width, height: source.height, format: kCVPixelFormatType_4444AYpCbCr16)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw Failure(reason: "pixel memory") }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let (kr, kb) = source.matrix.coefficients
        for y in 0..<source.height {
            let row = (base + y * rowBytes).assumingMemoryBound(to: UInt16.self)
            for x in 0..<source.width {
                let (straight, alpha) = Self.straightPixel(x: x, y: y, width: source.width, height: source.height)
                let weight = source.premultiplied ? Double(alpha) / 255 : 1
                let (r, g, b) = (straight[0] * weight, straight[1] * weight, straight[2] * weight)
                let luma = kr * r + (1 - kr - kb) * g + kb * b
                let cb = (b - luma) / (2 * (1 - kb))
                let cr = (r - luma) / (2 * (1 - kr))
                row[x * 4] = UInt16(alpha) * 257
                row[x * 4 + 1] = UInt16(((16 + 219 * luma) * 256).rounded())
                row[x * 4 + 2] = UInt16(((128 + 224 * cb) * 256).rounded())
                row[x * 4 + 3] = UInt16(((128 + 224 * cr) * 256).rounded())
            }
        }
        if source.premultiplied {
            CVBufferSetAttachment(
                buffer, kCVImageBufferAlphaChannelModeKey, kCVImageBufferAlphaChannelMode_PremultipliedAlpha,
                .shouldPropagate)
        }
        return buffer
    }

    private func writeOverlay(_ source: Source, to url: URL) async throws {
        var settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.proRes4444, AVVideoWidthKey: source.width,
            AVVideoHeightKey: source.height,
        ]
        if source.tagged {
            settings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: source.matrix.tag,
            ]
        }
        try await writeVideo(to: url, fileType: .mov, settings: settings, frame: try overlayFrame(source))
    }

    /// Серое (0x80) видео H.264 того же размера — основа, поверх которой кладётся анимация.
    private func writeGrayBase(width: Int, height: Int, to url: URL) async throws {
        let frame = try makeBuffer(width: width, height: height, format: kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(frame, [])
        if let base = CVPixelBufferGetBaseAddress(frame) {
            let rowBytes = CVPixelBufferGetBytesPerRow(frame)
            for y in 0..<height {
                let row = (base + y * rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width {
                    row[x * 4] = Self.gray
                    row[x * 4 + 1] = Self.gray
                    row[x * 4 + 2] = Self.gray
                    row[x * 4 + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(frame, [])
        try await writeVideo(
            to: url, fileType: .mp4,
            settings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
            ],
            frame: frame)
    }

    // MARK: - Чтение результата

    /// Дорожка жива, пока жив её ассет: ассет держит тот, кто вызывает.
    private func videoTrack(of asset: AVAsset) async throws -> AVAssetTrack {
        try #require(try await asset.loadTracks(withMediaType: .video).first)
    }

    private func formatTags(_ url: URL) async throws -> [String: Any] {
        let asset = AVURLAsset(url: url)
        let format = try #require(try await videoTrack(of: asset).load(.formatDescriptions).first)
        return CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
    }

    /// Время показа каждого кадра, без декодирования.
    private func frameTimes(_ asset: AVAsset) async throws -> [CMTime] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: try await videoTrack(of: asset), outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? Failure(reason: "read") }
        var times: [CMTime] = []
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) > 0 { times.append(CMSampleBufferGetPresentationTimeStamp(sample)) }
        }
        return times
    }

    /// Кадр 0,5 с стандартной видеокомпозиции: анимация поверх серой основы, непрозрачность 1.
    private func compositeFrame(overlay: URL, base: URL, size: CGSize) async throws -> CVPixelBuffer {
        let composition = AVMutableComposition()
        let baseAsset = AVURLAsset(url: base)
        let overlayAsset = AVURLAsset(url: overlay)
        let baseSource = try await videoTrack(of: baseAsset)
        let overlaySource = try await videoTrack(of: overlayAsset)
        let baseTrack = try #require(
            composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        try baseTrack.insertTimeRange(try await baseSource.load(.timeRange), of: baseSource, at: .zero)
        let overlayTrack = try #require(
            composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        try overlayTrack.insertTimeRange(try await overlaySource.load(.timeRange), of: overlaySource, at: .zero)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
        let overlayLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: overlayTrack)
        overlayLayer.setOpacity(1, at: .zero)
        let baseLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: baseTrack)
        instruction.layerInstructions = [overlayLayer, baseLayer]
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = size
        videoComposition.frameDuration = CMTime(value: 1, timescale: Self.fps)
        videoComposition.instructions = [instruction]

        let reader = try AVAssetReader(asset: composition)
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: [baseTrack, overlayTrack],
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = videoComposition
        reader.add(output)
        reader.timeRange = CMTimeRange(
            start: CMTime(value: 15, timescale: Self.fps), duration: CMTime(value: 1, timescale: Self.fps))
        guard reader.startReading() else { throw reader.error ?? Failure(reason: "composite") }
        defer { reader.cancelReading() }
        let sample = try #require(output.copyNextSampleBuffer())
        return try #require(CMSampleBufferGetImageBuffer(sample))
    }

    private func pixel(_ buffer: CVPixelBuffer, _ point: (Int, Int)) -> RGB {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else {
            return RGB(r: -1, g: -1, b: -1)
        }
        let at = base + point.1 * CVPixelBufferGetBytesPerRow(buffer) + point.0 * 4
        return RGB(r: Int(at[2]), g: Int(at[1]), b: Int(at[0]))
    }

    private func isClose(_ pixel: RGB, to expected: RGB, within tolerance: Int) -> Bool {
        abs(pixel.r - expected.r) <= tolerance && abs(pixel.g - expected.g) <= tolerance
            && abs(pixel.b - expected.b) <= tolerance
    }

    // MARK: - Тесты

    @Test("the prepared animation blends over video as it was designed", arguments: sources)
    func blendsOverVideo(_ source: Source) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input.mov")
        let prepared = directory.appendingPathComponent("prepared.mov")
        let base = directory.appendingPathComponent("base.mp4")
        try await writeOverlay(source, to: input)
        // Вход записан так, как задумано в сценарии, иначе тест ничего не доказывает.
        let inputTags = try await formatTags(input)
        #expect(
            inputTags[kCVImageBufferYCbCrMatrixKey as String] as? String == (source.tagged ? source.matrix.tag : nil))
        #expect(
            (inputTags[kCVImageBufferAlphaChannelModeKey as String] as? String
                == kCVImageBufferAlphaChannelMode_PremultipliedAlpha as String) == source.premultiplied)

        try await OverlayMediaNormalizer.normalize(input, to: prepared)

        let tags = try await formatTags(prepared)
        #expect(
            tags[kCVImageBufferAlphaChannelModeKey as String] as? String
                == kCVImageBufferAlphaChannelMode_PremultipliedAlpha as String)
        #expect(tags[kCVImageBufferYCbCrMatrixKey as String] as? String == AVVideoYCbCrMatrix_ITU_R_709_2)
        #expect(tags[kCVImageBufferColorPrimariesKey as String] as? String == AVVideoColorPrimaries_ITU_R_709_2)
        #expect(
            tags[kCVImageBufferTransferFunctionKey as String] as? String == AVVideoTransferFunction_ITU_R_709_2)
        let preparedAsset = AVURLAsset(url: prepared)
        let inputAsset = AVURLAsset(url: input)
        #expect(
            try await videoTrack(of: preparedAsset).load(.naturalSize)
                == CGSize(width: source.width, height: source.height))
        #expect(try await frameTimes(preparedAsset) == (try await frameTimes(inputAsset)))
        #expect(try await preparedAsset.load(.duration) == (try await inputAsset.load(.duration)))
        #expect(try await preparedAsset.loadTracks(withMediaType: .audio).isEmpty)

        try await writeGrayBase(width: source.width, height: source.height, to: base)
        let frame = try await compositeFrame(
            overlay: prepared, base: base, size: CGSize(width: source.width, height: source.height))
        let points = Self.probes(width: source.width, height: source.height)
        let centre = pixel(frame, points.centre)
        let band = pixel(frame, points.band)
        let corner = pixel(frame, points.corner)
        // Белый с альфой 0,5 поверх серого 0x80: 128 + 127 × 0,5 ≈ 191.
        #expect(isClose(centre, to: RGB(r: 255, g: 0, b: 0), within: 12), "centre \(centre)")
        #expect(isClose(band, to: RGB(r: 191, g: 191, b: 191), within: 25), "band \(band)")
        #expect(isClose(corner, to: RGB(r: 128, g: 128, b: 128), within: 6), "corner \(corner)")
    }

    // MARK: - Отмена

    @Test("an already cancelled preparation leaves no file")
    func taskCancelBeforeRun() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input.mov")
        try await writeOverlay(Self.sources[0], to: input)
        let preparation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await OverlayMediaNormalizer.normalize(input, to: directory.appendingPathComponent("prepared.mov"))
        }
        let result = await preparation.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["input.mov"])
    }

    /// Флаг «отменили» говорит «нет» при первом вопросе и «да» потом: подготовка обязана
    /// заметить это посреди записи, а не только после последнего кадра.
    @Test("cancelling through the flag mid-run stops early and leaves no file")
    func flagCancelMidRun() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input.mov")
        try await writeOverlay(Self.sources[0], to: input)
        let checks = OSAllocatedUnfairLock(initialState: 0)

        await #expect(throws: CancellationError.self) {
            try await OverlayMediaNormalizer.normalize(
                input, to: directory.appendingPathComponent("prepared.mov"),
                isCancelled: {
                    checks.withLock {
                        $0 += 1
                        return $0 > 1
                    }
                })
        }
        // Вопрос задаётся на каждом кадре: остановка на втором вопросе — не в конце файла.
        #expect(checks.withLock { $0 } < Self.frameCount)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["input.mov"])
    }

    /// Отмена задачи Swift, которая ждёт подготовку, тоже останавливает запись: флаг при этом
    /// всё время отвечает «нет», как `{ Task.isCancelled }` на чужой очереди.
    @Test("cancelling the calling task mid-run stops early and leaves no file")
    func taskCancelMidRun() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input.mov")
        try await writeOverlay(Self.sources[0], to: input)
        let checks = OSAllocatedUnfairLock(initialState: 0)
        let running = DispatchSemaphore(value: 0)
        // Ворота: закрыты, пока тест не отменит задачу, потом открыты для всех.
        let gate = DispatchGroup()
        gate.enter()

        let preparation = Task {
            try await OverlayMediaNormalizer.normalize(
                input, to: directory.appendingPathComponent("prepared.mov"),
                isCancelled: {
                    // Вопрос приходит уже во время записи. Каждый ждёт у ворот: ни один кадр
                    // не проскочит, пока задачу не отменят.
                    if checks.withLock({
                        $0 += 1
                        return $0
                    }) == 1 {
                        running.signal()
                    }
                    _ = gate.wait(timeout: .now() + 30)
                    return false
                })
        }
        let started = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async {
                continuation.resume(returning: running.wait(timeout: .now() + 30) == .success)
            }
        }
        #expect(started, "the pump never asked whether it was cancelled")
        preparation.cancel()
        gate.leave()

        let result = await preparation.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(checks.withLock { $0 } < Self.frameCount)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["input.mov"])
    }
}
