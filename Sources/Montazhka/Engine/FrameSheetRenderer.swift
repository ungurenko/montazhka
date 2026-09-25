@preconcurrency import AVFoundation
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum FrameSheetError: LocalizedError {
    case noTimes
    case noVideo
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .noTimes: "Не указано ни одного момента для кадров."
        case .noVideo: "Ни один кадр не удалось извлечь: в видео нет картинки на этих моментах."
        case .writeFailed: "Не удалось сохранить картинку с кадрами."
        }
    }
}

/// «Контактный лист»: несколько кадров одной JPEG-сеткой с подписанным временем —
/// так агент за один взгляд видит кусок ролика.
enum FrameSheetRenderer {
    static let maxFrames = 16
    private static let sheetWidth = 1280.0
    private static let labelHeight = 28.0

    /// `labels` — подписи к кадрам (по умолчанию время из `times`).
    /// Кадр с надписями поверх: надписи рисуются в размер кадра.
    private static func composite(_ frame: CGImage, _ overlay: CGImage) -> CGImage? {
        let rect = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        guard
            let context = CGContext(
                data: nil, width: frame.width, height: frame.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(frame, in: rect)
        context.draw(overlay, in: rect)
        return context.makeImage()
    }

    static func render(
        asset: AVAsset, videoComposition: AVVideoComposition? = nil,
        times: [Double], labels: [String]? = nil, to url: URL,
        overlayAt: ((Double) -> CGImage?)? = nil
    ) async throws -> (extracted: Int, width: Int, height: Int) {
        let times = Array(times.prefix(maxFrames))
        guard !times.isEmpty else { throw FrameSheetError.noTimes }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.videoComposition = videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)

        let columns = times.count <= 4 ? times.count : (times.count <= 6 ? 3 : 4)
        let cellWidth = (sheetWidth / Double(columns)).rounded(.down)
        generator.maximumSize = CGSize(width: cellWidth * 2, height: cellWidth * 2)

        var images: [CGImage?] = []
        for time in times {
            let image = try? await generator.image(at: CMTime(seconds: max(0, time), preferredTimescale: 600)).image
            images.append(image.map { frame in overlayAt?(time).flatMap { composite(frame, $0) } ?? frame })
        }
        guard let sample = images.compactMap({ $0 }).first else { throw FrameSheetError.noVideo }
        let aspect = Double(sample.height) / Double(max(1, sample.width))
        let imageHeight = (cellWidth * aspect).rounded(.down)
        let rows = (times.count + columns - 1) / columns
        let width = Int(cellWidth) * columns
        let height = Int(imageHeight + labelHeight) * rows

        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw FrameSheetError.writeFailed }
        context.setFillColor(CGColor(gray: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let texts = labels ?? times.map(timecode)
        for (index, image) in images.enumerated() {
            let column = index % columns
            let row = index / columns
            let x = Double(column) * cellWidth
            // У CGContext начало координат внизу — первая строка рисуется сверху.
            let top = Double(height) - Double(row) * (imageHeight + labelHeight)
            let imageRect = CGRect(x: x + 1, y: top - imageHeight, width: cellWidth - 2, height: imageHeight - 1)
            if let image {
                context.draw(image, in: imageRect)
            } else {
                context.setFillColor(CGColor(gray: 0.3, alpha: 1))
                context.fill(imageRect)
            }
            let label = index < texts.count ? texts[index] : ""
            drawLabel(
                image == nil ? "\(label) (нет кадра)" : label, in: context,
                at: CGPoint(x: x + 8, y: top - imageHeight - labelHeight + 8))
        }

        guard let sheet = context.makeImage(),
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw FrameSheetError.writeFailed }
        CGImageDestinationAddImage(
            destination, sheet, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw FrameSheetError.writeFailed }
        return (images.compactMap { $0 }.count, width, height)
    }

    /// Равномерные моменты внутри диапазона — середины равных частей.
    static func evenTimes(from: Double, to: Double, count: Int) -> [Double] {
        let count = max(1, min(maxFrames, count))
        let step = (to - from) / Double(count)
        return (0..<count).map { from + step * (Double($0) + 0.5) }
    }

    static func timecode(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let rest = seconds - Double(minutes * 60)
        return String(format: "%d:%05.2f", minutes, rest)
    }

    private static func drawLabel(_ text: String, in context: CGContext, at point: CGPoint) {
        let font = CTFontCreateWithName("Menlo" as CFString, 15, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = point
        CTLineDraw(line, context)
    }
}
