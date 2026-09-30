@preconcurrency import AVFoundation
import CoreVideo
import Foundation

@testable import MontazhkaKit

/// Меняющиеся кадры: однотонная существующая fixture не ловит ошибку выбора соседнего кадра.
enum SeamFrameFixture {
    struct Failure: Error { let reason: String }

    static func write(to url: URL, codec: AVVideoCodecType, fps: Int32) async throws {
        let times =
            fps == 0
            ? [0, 0.02, 0.07, 0.09, 0.17, 0.24, 0.36, 0.39, 0.50, 0.61, 0.74, 0.79]
            : (0..<Int(fps * 4 / 5)).map { Double($0) / Double(fps) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: codec, AVVideoWidthKey: 64, AVVideoHeightKey: 36,
                AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 6],
            ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? Failure(reason: "start") }
        writer.startSession(atSourceTime: .zero)
        let deadline = ContinuousClock.now + .seconds(30)
        for (index, time) in times.enumerated() {
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, ContinuousClock.now < deadline else {
                    writer.cancelWriting()
                    throw Failure(reason: "writer stalled")
                }
                try await Task.sleep(for: .milliseconds(2))
            }
            var created: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 36, kCVPixelFormatType_32BGRA, nil, &created)
            guard let frame = created else { throw Failure(reason: "pixel buffer") }
            CVPixelBufferLockBaseAddress(frame, [])
            let base = CVPixelBufferGetBaseAddress(frame)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(frame)
            for y in 0..<36 {
                for x in 0..<64 {
                    let pixel = base + y * stride + x * 4
                    let value = UInt8(8 + (index * 37 + (x < 32 ? 0 : 11)) % 230)
                    pixel[0] = value
                    pixel[1] = value
                    pixel[2] = value
                    pixel[3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(frame, [])
            guard adaptor.append(frame, withPresentationTime: CMTime(seconds: time, preferredTimescale: 600)) else {
                writer.cancelWriting()
                throw writer.error ?? Failure(reason: "append")
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 4, timescale: 5))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? Failure(reason: "finish") }
    }

    /// Эталон до оптимизации: отдельный reader на каждый момент, тот же формат и сетка яркости.
    static func legacyLuma(asset: AVAsset, times: [Double]) async throws -> [Double] {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw SeamProbeError.noVideo
        }
        return try times.map { time in
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(
                track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            output.alwaysCopiesSampleData = false
            reader.add(output)
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: max(0, time), preferredTimescale: 600), duration: CMTime(value: 1, timescale: 5))
            guard reader.startReading() else { throw SeamProbeError.unreadable }
            defer { reader.cancelReading() }
            guard let sample = output.copyNextSampleBuffer(), let buffer = CMSampleBufferGetImageBuffer(sample) else {
                throw SeamProbeError.noFrame(time)
            }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
            let columns = min(64, width)
            let rows = max(1, Int((Double(height) * Double(columns) / Double(width)).rounded()))
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            var sum = 0.0
            for row in 0..<rows {
                let y = min(height - 1, Int((Double(row) + 0.5) * Double(height) / Double(rows)))
                for column in 0..<columns {
                    let x = min(width - 1, Int((Double(column) + 0.5) * Double(width) / Double(columns)))
                    let pixel = base + y * stride + x * 4
                    sum += 0.0722 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.2126 * Double(pixel[2])
                }
            }
            return sum / Double(rows * columns) / 255
        }
    }
}
