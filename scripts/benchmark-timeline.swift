import CryptoKit
import Darwin
import Foundation
import SwiftUI

@testable import MontazhkaKit

@main
struct TimelineBenchmark {
    static func main() throws {
        let baseline = CommandLine.arguments.contains("baseline")
        let pps = Double(CommandLine.arguments.last ?? "240") ?? 240
        let clip = Clip(sourcePath: "/tmp/benchmark.mov", start: 0, end: 7200)
        let peaks = (0..<720_000).map { Float($0 % 97) / 97 }
        let size = CGSize(width: 7200 * pps, height: 80)
        let viewport = CGRect(x: size.width / 2 + 0.5, y: 0, width: 1200, height: 100)
        let range = TimelineDrawingRange.local(contentX: 12, width: size.width, viewport: viewport)
        func draw() -> Path {
            baseline
                ? TimelineWaveformFixture.original(clip: clip, peaks: peaks, size: size)
                : TimelineWaveformDrawing.path(clip: clip, peaks: peaks, size: size, range: range)
        }
        _ = draw()
        let start = ContinuousClock.now
        let path = draw()
        let elapsed = ContinuousClock.now - start
        let pixels = TimelineWaveformFixture.pixels(path, offset: viewport.minX - 12)
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let result: [String: Any] = [
            "mode": baseline ? "baseline" : "viewport", "pps": pps,
            "seconds": Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
            "peakRSSBytes": usage.ru_maxrss,
            "cpuSeconds": Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6,
            "rectangles": baseline ? Int(ceil(size.width / 2)) : Int(ceil(range.upperBound / 2) - floor(range.lowerBound / 2)),
            "digest": SHA256.hash(data: pixels).map { String(format: "%02x", $0) }.joined(),
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: .sortedKeys), as: UTF8.self))
    }
}
