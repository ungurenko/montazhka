@preconcurrency import AVFoundation
import Foundation
import OSLog
import Testing

@testable import MontazhkaKit

@Suite("Seam frame selection matches the independent-reader reference", .serialized)
struct SeamFrameReadingTests {
    @Test(arguments: [AVVideoCodecType.h264, .hevc], [Int32(30), 60, 0])
    func preservesFrames(codec: AVVideoCodecType, fps: Int32) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("seam-frames-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("frames.mov")
        try await SeamFrameFixture.write(to: file, codec: codec, fps: fps)
        let asset = AVURLAsset(url: file)
        let cases: [[Double]] = [
            [], [0, 0.12], [0.011, 0.131], [0.05, 0.17], [0.05, 0.25], [0.18, 0.30], [0.31, 0.44],
            [0.71, 0.799], [0.13, 0.13], [0.2, 0.1], [0.1, 0.301], [-0.2, 0.04],
            [0.011, 0.131, 0.4, 0.52, 0.1],
        ]
        for times in cases {
            let expected = try await SeamFrameFixture.legacyLuma(asset: asset, times: times)
            let actual = try await SeamProbe.meanLuma(asset: asset, times: times)
            #expect(actual == expected, "codec=\(codec), fps=\(fps), times=\(times)")
        }
        for times in [[0.79, 0.81], [0.72, 1.5], [1.5, 0.72]] {
            let expected = await failure { try await SeamFrameFixture.legacyLuma(asset: asset, times: times) }
            let actual = await failure { try await SeamProbe.meanLuma(asset: asset, times: times) }
            #expect(actual == expected)
            #expect(expected != nil)
        }
    }

    private func failure(_ operation: () async throws -> [Double]) async -> String? {
        do { _ = try await operation(); return nil } catch { return error.localizedDescription }
    }

    @Test
    func noVideoKeepsItsError() async {
        let asset = AVMutableComposition()
        let expected = await failure { try await SeamFrameFixture.legacyLuma(asset: asset, times: [0, 0.12]) }
        let actual = await failure { try await SeamProbe.meanLuma(asset: asset, times: [0, 0.12]) }
        #expect(actual == expected)
        #expect(expected == SeamProbeError.noVideo.localizedDescription)
    }

    @Test("nearby frames share a reader; distant and reversed requests keep independent readers")
    func readerCountProtectsTheImprovement() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("seam-reader-count-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("frames.mov")
        try await SeamFrameFixture.write(to: file, codec: .h264, fps: 30)
        let asset = AVURLAsset(url: file)
        for (times, expected) in [
            ([0.011, 0.131, 0.31, 0.431], 2), ([0.01, 0.3], 2), ([0.2, 0.1], 2), ([0.13, 0.13], 1),
        ] {
            let starts = OSAllocatedUnfairLock(initialState: 0)
            _ = try await SeamProbe.meanLuma(asset: asset, times: times, onReaderStart: { starts.withLock { $0 += 1 } })
            #expect(starts.withLock { $0 } == expected)
        }
    }
}
