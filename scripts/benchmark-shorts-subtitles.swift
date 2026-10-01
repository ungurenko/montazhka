import CryptoKit
import Foundation

@testable import MontazhkaKit

/// A 45-second preview from a one-hour transcript. Measures subtitle data
/// preparation and per-frame selection separately, without media or providers.
@main
struct ShortsSubtitleBenchmark {
    static func main() throws {
        let sourceID = UUID()
        let words = (0..<18_000).map { index in
            TranscriptWord(
                sourceID: sourceID, text: "слово\(index)",
                start: Double(index) * 0.2, end: Double(index) * 0.2 + 0.15, confidence: 1)
        }
        let map = ShortsTimeMap(segments: [
            ShortsSegment(start: 3000, end: 3020),
            ShortsSegment(start: 3022, end: 3047),
        ])
        let mode = ShortsSubtitleMode.on(words: words, appearance: .default, highlight: true)
        let preparationStart = ContinuousClock.now
        let cues = ShortsSubtitleCueBuilder.make(words: words, timeMap: map)
        let preparation = seconds(ContinuousClock.now - preparationStart)
        let times = (0..<1350).map { Double($0) / 30 }

        func run(cached: Bool) -> (elapsed: Double, digest: String) {
            var digest = SHA256()
            let start = ContinuousClock.now
            for time in times {
                let overlay =
                    cached
                    ? ShortsSubtitleOverlayBuilder.make(
                        at: time, cues: cues, appearance: .default, highlight: true)
                    : ShortsSubtitleOverlayBuilder.make(at: time, timeMap: map, mode: mode)
                let frame = "\(overlay?.text ?? "")|\(overlay?.activeWordIndex ?? -1)\n"
                digest.update(data: Data(frame.utf8))
            }
            return (
                seconds(ContinuousClock.now - start),
                digest.finalize().map { String(format: "%02x", $0) }.joined()
            )
        }

        _ = run(cached: false)
        _ = run(cached: true)
        var baseline: [Double] = []
        var cached: [Double] = []
        var frameDigest = ""
        for index in 0..<3 {
            let first = run(cached: index.isMultiple(of: 2))
            let second = run(cached: !index.isMultiple(of: 2))
            guard first.digest == second.digest else {
                throw BenchmarkError.changedFrames
            }
            cached.append(index.isMultiple(of: 2) ? first.elapsed : second.elapsed)
            baseline.append(index.isMultiple(of: 2) ? second.elapsed : first.elapsed)
            frameDigest = first.digest
        }
        let result: [String: Any] = [
            "transcriptWords": words.count,
            "previewFrames": times.count,
            "cues": cues.count,
            "preparationSeconds": preparation,
            "baselineSeconds": baseline,
            "cachedSeconds": cached,
            "baselineMedianSeconds": baseline.sorted()[1],
            "cachedMedianSeconds": cached.sorted()[1],
            "identicalFrameDigest": frameDigest,
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: .sortedKeys), as: UTF8.self))
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private enum BenchmarkError: Error { case changedFrames }
}
