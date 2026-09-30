@preconcurrency import AVFoundation
import CryptoKit
import Darwin
import Foundation

@testable import MontazhkaKit

/// Изолированный проект; исходник только читается, модели и провайдеры не запускаются.
@main
struct SeamCheckBenchmark {
    static func seconds(_ value: Duration) -> Double {
        Double(value.components.seconds) + Double(value.components.attoseconds) / 1e18
    }

    static func digest<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }

    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 2 else { throw SeamFrameFixture.Failure(reason: "fixture directory required") }
        let root = URL(fileURLWithPath: args[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let service = AgentService(
            baseDirectory: root,
            startJob: { _ in
                .failure(command: "submit", code: "BENCHMARK", message: "Background jobs are disabled.")
            })
        let fixtureURL = root.appendingPathComponent("fixture.json")
        let project: Project
        if FileManager.default.fileExists(atPath: fixtureURL.path) {
            project = try JSONDecoder().decode(Project.self, from: Data(contentsOf: fixtureURL))
            if args.count >= 3,
                project.clips.first?.url.standardizedFileURL != URL(fileURLWithPath: args[2]).standardizedFileURL
            {
                throw SeamFrameFixture.Failure(
                    reason: "The saved benchmark fixture uses another source; use a fresh fixture directory.")
            }
        } else {
            let file: URL
            if args.count >= 3 {
                file = URL(fileURLWithPath: args[2]).standardizedFileURL
            } else {
                file = root.appendingPathComponent("frames.mov")
                try await SeamFrameFixture.write(to: file, codec: .h264, fps: 60)
            }
            let duration = try await AVURLAsset(url: file).load(.duration).seconds
            let source = MediaReference(path: file.path)
            let length = duration / 41
            project = Project(
                name: "Seam performance fixture",
                clips: (0..<41).map { Clip(source: source, start: Double($0) * length, end: Double($0 + 1) * length) })
            try await service.store.save(project)
            try JSONEncoder().encode(project).write(to: fixtureURL, options: .atomic)
        }
        let file = project.clips[0].url
        let asset = AVURLAsset(url: file)
        let duration = try await asset.load(.duration).seconds
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let size = try await track.load(.naturalSize)
        let clock = ContinuousClock()
        var readerStarts = 0
        var brightness: [Double] = []
        let start = clock.now
        for cut in 1...40 {
            let time = Double(cut) * duration / 41
            let times = [max(0, time - 0.08), min(duration - 0.01, time + 0.04)]
            for _ in 0..<2 {
                brightness += try await SeamProbe.meanLuma(
                    asset: asset, times: times, onReaderStart: { readerStarts += 1 })
            }
        }
        let frameSeconds = seconds(clock.now - start)
        let checkStart = clock.now
        var response = await service.check(
            AgentCheckRequest(projectID: project.id, filePath: file.path, words: false, includeLoudness: false))
        let checkSeconds = seconds(clock.now - checkStart)
        guard response.ok else {
            throw SeamFrameFixture.Failure(reason: "check failed: \(String(describing: response.error))")
        }
        guard case .array(let cuts)? = response.data?["cuts"], cuts.count == 40 else {
            throw SeamFrameFixture.Failure(reason: "expected a complete page of 40 cuts")
        }
        let imagePath = response.data?.removeValue(forKey: "imagePath")
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpu =
            Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        guard case .string(let sheetPath)? = imagePath else {
            throw SeamFrameFixture.Failure(reason: "expected a comparison sheet")
        }
        let imageDigest = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: sheetPath)))
            .map { String(format: "%02x", $0) }.joined()
        let result: [String: AgentJSONValue] = [
            "sourceMinutes": .number(duration / 60), "width": .number(size.width), "height": .number(size.height),
            "frameSeconds": .number(frameSeconds), "readerStarts": .number(Double(readerStarts)),
            "checkSeconds": .number(checkSeconds), "cpuSeconds": .number(cpu),
            "peakRSSBytes": .number(Double(usage.ru_maxrss)),
            "lumaDigest": .string(try digest(brightness)), "responseDigest": .string(try digest(response)),
            "imageDigest": .string(imageDigest),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(result), as: UTF8.self))
    }
}
