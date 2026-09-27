@preconcurrency import AVFoundation
import CoreVideo
import Foundation

/// Анимация для проверок — такая, какой её оставляет `OverlayMediaNormalizer`: ProRes 4444
/// с premultiplied-альфой и пометками BT.709. Прозрачный фон, непрозрачный красный квадрат
/// в центре, белая полоса с альфой 0,5 в верхней четверти.
enum TestOverlayFactory {
    struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// Точки проверки в кадре анимации: центр квадрата, середина полосы, прозрачный угол.
    static func probes(width: Int, height: Int) -> (centre: CGPoint, band: CGPoint, corner: CGPoint) {
        (
            CGPoint(x: width / 2, y: height / 2), CGPoint(x: width / 8, y: height / 8),
            CGPoint(x: width - 4, y: height - 4)
        )
    }

    static func make(width: Int, height: Int, duration: Double, fps: Int32 = 30, to url: URL) async throws {
        try await writeStill(
            try overlayFrame(width: width, height: height),
            settings: [
                AVVideoCodecKey: AVVideoCodecType.proRes4444, AVVideoWidthKey: width, AVVideoHeightKey: height,
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
            ],
            fileType: .mov, frameCount: Int((duration * Double(fps)).rounded()),
            frameDuration: CMTime(value: 1, timescale: fps), to: url)
    }

    /// Пишет видео из одного и того же кадра через `requestMediaDataWhenReady`: ручной
    /// опрос `isReadyForMoreMediaData` может повиснуть. `frameDuration` — шаг кадров
    /// (например, 1001/30000 для 29,97 к/с). `transform` — поворот дорожки, как у
    /// вертикального ролика с iPhone.
    static func writeStill(
        _ frame: CVPixelBuffer, settings: [String: Any], fileType: AVFileType, frameCount: Int,
        frameDuration: CMTime,
        transform: CGAffineTransform = .identity, to url: URL
    ) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? Failure(reason: "Запись не началась") }
        writer.startSession(atSourceTime: .zero)

        let feed = FeedIO(input: input, adaptor: adaptor, frame: frame)
        let fed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let queue = DispatchQueue(label: "selftest.overlay-feed")
            let state = FeedState()
            queue.asyncAfter(deadline: .now() + .seconds(30)) {
                guard !state.done else { return }
                state.done = true
                continuation.resume(returning: false)
            }
            feed.input.requestMediaDataWhenReady(on: queue) {
                while feed.input.isReadyForMoreMediaData, !state.done {
                    guard state.index < frameCount else {
                        state.done = true
                        feed.input.markAsFinished()
                        continuation.resume(returning: true)
                        return
                    }
                    let time = CMTimeMultiply(frameDuration, multiplier: Int32(state.index))
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
            throw Failure(reason: "Запись тестового видео зависла: \(url.lastPathComponent)")
        }
        writer.endSession(atSourceTime: CMTimeMultiply(frameDuration, multiplier: Int32(frameCount)))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? Failure(reason: "Запись не завершилась") }
    }

    static func pixelBuffer(width: Int, height: Int, format: OSType) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        CVPixelBufferCreate(nil, width, height, format, attributes, &created)
        guard let buffer = created else { throw Failure(reason: "Не удалось создать кадр") }
        return buffer
    }

    /// Кадр в YCbCr 4:4:4 с альфой (y416, limited-диапазон, BT.709), цвет уже умножен на альфу.
    /// Считается вручную: писатель AVFoundation из BGRA не даёт выбрать матрицу.
    private static func overlayFrame(width: Int, height: Int) throws -> CVPixelBuffer {
        let buffer = try pixelBuffer(width: width, height: height, format: kCVPixelFormatType_4444AYpCbCr16)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw Failure(reason: "Нет памяти кадра") }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let (kr, kb) = (0.2126, 0.0722)
        let half = max(4, height / 8)
        for y in 0..<height {
            let row = (base + y * rowBytes).assumingMemoryBound(to: UInt16.self)
            for x in 0..<width {
                let (rgb, alpha): ([Double], UInt16)
                if abs(x - width / 2) < half, abs(y - height / 2) < half {
                    (rgb, alpha) = ([1, 0, 0], 255)
                } else if y < height / 4 {
                    (rgb, alpha) = ([1, 1, 1], 128)
                } else {
                    (rgb, alpha) = ([0, 0, 0], 0)
                }
                let weight = Double(alpha) / 255
                let (r, g, b) = (rgb[0] * weight, rgb[1] * weight, rgb[2] * weight)
                let luma = kr * r + (1 - kr - kb) * g + kb * b
                row[x * 4] = alpha * 257
                row[x * 4 + 1] = UInt16(((16 + 219 * luma) * 256).rounded())
                row[x * 4 + 2] = UInt16(((128 + 224 * (b - luma) / (2 * (1 - kb))) * 256).rounded())
                row[x * 4 + 3] = UInt16(((128 + 224 * (r - luma) / (2 * (1 - kr))) * 256).rounded())
            }
        }
        CVBufferSetAttachment(
            buffer, kCVImageBufferAlphaChannelModeKey, kCVImageBufferAlphaChannelMode_PremultipliedAlpha,
            .shouldPropagate)
        return buffer
    }

    private struct FeedIO: @unchecked Sendable {
        let input: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let frame: CVPixelBuffer
    }

    /// Рабочее состояние колбэка писателя — меняется только с его очереди.
    private final class FeedState: @unchecked Sendable {
        var index = 0
        var done = false
    }
}
