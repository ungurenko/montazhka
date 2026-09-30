@preconcurrency import AVFoundation
import CoreImage
import CoreVideo

/// Кладёт надписи на кадры при покадровой записи. Кадр без надписей идёт в писатель
/// как есть; кадр с надписями Core Image собирает в новый буфер того же формата,
/// размера и цвета (пометки буфера переносятся), время кадра не меняется.
/// Зовётся с одной очереди насоса — состояние без замка.
final class FrameOverlayBurner: @unchecked Sendable {
    private let overlay: @Sendable (Double) -> CGImage?
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool?
    private var poolKey: (width: Int, height: Int, format: OSType)?
    private var lastImage: CGImage?
    private var lastOverlay: CIImage?
    /// Надпись была, а на кадр не легла (нет памяти под кадр и т. п.): запись — ошибка.
    private(set) var didFail = false

    init(overlay: @escaping @Sendable (Double) -> CGImage?) {
        self.overlay = overlay
    }

    func burn(_ sample: CMSampleBuffer) -> CMSampleBuffer {
        // Колбэк reader может обработать много кадров до возврата в RunLoop.
        // Освобождаем временные Core Image/AVFoundation объекты после каждого кадра.
        autoreleasepool {
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard let image = overlay(time) else { return sample }
            guard let source = CMSampleBufferGetImageBuffer(sample), let target = makeBuffer(like: source) else {
                didFail = true
                return sample
            }
            CVBufferPropagateAttachments(source, target)
            let base = CIImage(cvPixelBuffer: source)
            let colorSpace =
                CVBufferCopyAttachments(source, .shouldPropagate).flatMap {
                    CVImageBufferCreateColorSpaceFromAttachments($0)?.takeRetainedValue()
                } ?? CGColorSpace(name: CGColorSpace.itur_709)
            context.render(
                overlayImage(image, fitting: base.extent).composited(over: base), to: target, bounds: base.extent,
                colorSpace: colorSpace)
            guard let burned = Self.sample(with: target, timingOf: sample) else {
                didFail = true
                return sample
            }
            return burned
        }
    }

    /// Картинка надписей того же размера, что кадр; у одинаковых подряд — одна и та же.
    private func overlayImage(_ image: CGImage, fitting extent: CGRect) -> CIImage {
        if image === lastImage, let lastOverlay { return lastOverlay }
        var result = CIImage(cgImage: image)
        if result.extent.size != extent.size, result.extent.width > 0, result.extent.height > 0 {
            result = result.transformed(
                by: CGAffineTransform(
                    scaleX: extent.width / result.extent.width, y: extent.height / result.extent.height))
        }
        lastImage = image
        lastOverlay = result
        return result
    }

    private func makeBuffer(like source: CVPixelBuffer) -> CVPixelBuffer? {
        let key = (
            width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source),
            format: CVPixelBufferGetPixelFormatType(source)
        )
        if poolKey.map({ $0 != key }) ?? true {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: key.format,
                kCVPixelBufferWidthKey as String: key.width,
                kCVPixelBufferHeightKey as String: key.height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            var created: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &created)
            pool = created
            poolKey = key
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }

    private static func sample(with buffer: CVPixelBuffer, timingOf original: CMSampleBuffer) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo()
        guard CMSampleBufferGetSampleTimingInfo(original, at: 0, timingInfoOut: &timing) == noErr else { return nil }
        var format: CMVideoFormatDescription?
        guard
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format) == noErr,
            let format
        else { return nil }
        var result: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: buffer, formatDescription: format, sampleTiming: &timing,
            sampleBufferOut: &result)
        return result
    }
}
