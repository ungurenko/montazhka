@preconcurrency import AVFoundation
import Foundation
import Testing

@testable import MontazhkaKit

/// Надпись, которую не удалось положить на кадр, — ошибка записи, а не тихий пропуск.
@Suite("Frame overlay burner")
struct FrameOverlayBurnerTests {
    @Test("a frame that cannot take its caption marks the burn as failed")
    func unburnableFrameFails() throws {
        let caption = try #require(
            CGContext(
                data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .makeImage())
        let burner = FrameOverlayBurner(overlay: { _ in caption })
        var empty: CMSampleBuffer?
        CMSampleBufferCreate(
            allocator: nil, dataBuffer: nil, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: nil, sampleCount: 0, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &empty)

        _ = burner.burn(try #require(empty))

        #expect(burner.didFail)
    }
}
