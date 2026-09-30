@preconcurrency import AVFoundation
import CryptoKit
import Darwin
import Foundation

@testable import MontazhkaKit

/// A shared fixture and fresh processes keep waveform disk/RAM caches explicit.
@main
struct InspectionBenchmark {
    static func main() async throws {
        let args = CommandLine.arguments
        let root = URL(fileURLWithPath: args[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = ProjectStore(baseDirectory: root)
        let fixture = root.appendingPathComponent("fixture.json")
        let service = AgentService(baseDirectory: root, startJob: { _ in
            .failure(command: "benchmark", code: "DISABLED", message: "Background jobs are disabled.")
        })
        let project: Project
        if FileManager.default.fileExists(atPath: fixture.path) {
            project = try JSONDecoder().decode(Project.self, from: Data(contentsOf: fixture))
        } else {
            let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
            let first = root.appendingPathComponent("source-0.caf")
            try autoreleasepool {
                let file = try AVAudioFile(forWriting: first, settings: format.settings)
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
                buffer.frameLength = 16000
                for second in 0..<600 {
                    for sample in 0..<16000 {
                        buffer.floatChannelData![0][sample] = second % 5 == 0
                            ? 0 : Float(sin(Double(sample) * 2 * .pi * 440 / 16000) * 0.25)
                    }
                    try file.write(from: buffer)
                }
            }
            var sources = [MediaReference(url: first)]
            for index in 1..<5 {
                let url = root.appendingPathComponent("source-\(index).caf")
                try FileManager.default.copyItem(at: first, to: url)
                sources.append(MediaReference(url: url))
            }
            project = Project(name: "Inspection benchmark", clips: sources.map { Clip(source: $0, start: 0, end: 20) })
            try await store.save(project)
            for source in sources {
                let url = await service.makeTranscriptStore().cacheURL(for: source)
                let words = (0..<20).map { index in
                    TranscriptWord(sourceID: source.id, text: "word\(index)", start: Double(index), end: Double(index) + 0.3, confidence: 1)
                }
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(TranscriptDocument(words: words)).write(to: url)
            }
            try JSONEncoder().encode(project).write(to: fixture)
        }
        if args.contains("prepare") { return }
        // This directory belongs exclusively to the benchmark fixture.
        if FileManager.default.fileExists(atPath: store.waveformsDir.path) {
            try FileManager.default.removeItem(at: store.waveformsDir)
        }
        try FileManager.default.createDirectory(at: store.waveformsDir, withIntermediateDirectories: true)
        let transcript = args.contains("transcript")
        let warm = args.contains("warm")
        func request() async -> AgentResponse {
            if transcript {
                return await service.transcript(
                    AgentTranscriptRequest(target: AgentMediaTarget(projectID: project.id), from: 1, to: 10))
            }
            return await service.audio(target: AgentMediaTarget(projectID: project.id), from: 1, to: 10, buckets: 60)
        }
        if warm { _ = await request() }
        let start = ContinuousClock.now
        let result = await request()
        guard result.ok else { throw CocoaError(.fileReadCorruptFile) }
        let elapsed = ContinuousClock.now - start
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(result)).map { String(format: "%02x", $0) }.joined()
        let loads = try FileManager.default.contentsOfDirectory(atPath: store.waveformsDir.path).filter { $0.hasSuffix(".f32") }.count
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let payload: [String: Any] = [
            "operation": transcript ? "transcript" : "audio", "warm": warm,
            "seconds": Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
            "waveformFiles": loads, "digest": digest, "peakRSSBytes": usage.ru_maxrss,
            "cpuSeconds": Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6,
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys), as: UTF8.self))
    }
}
