@preconcurrency import AVFoundation
import Darwin
import Foundation

@testable import MontazhkaKit

private final class PreviewPreferences: PreferenceStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var strings: [String: String] = [:]
    private var bools: [String: Bool] = [:]
    func string(forKey key: String) -> String? { lock.withLock { strings[key] } }
    func set(_ value: String?, forKey key: String) { lock.withLock { strings[key] = value } }
    func bool(forKey key: String) -> Bool { lock.withLock { bools[key] ?? false } }
    func set(_ value: Bool, forKey key: String) { lock.withLock { bools[key] = value } }
}

@MainActor
private final class CountingPreviewBuilder: ShortsPreviewBuilding {
    var builds = 0
    func makeItem(for request: ShortsPreviewRequest) async throws -> ShortsPreviewItem {
        builds += 1
        return try await DefaultShortsPreviewBuilder().makeItem(for: request)
    }
}

@main
struct PreviewBenchmark {
    @MainActor
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.mov")
        if !FileManager.default.fileExists(atPath: source.path) {
            try await TestVideoFactory.make(segments: [(duration: 3, loud: false)], videoLuma: 128, to: source)
        }
        if CommandLine.arguments.contains("prepare") { return }
        let builder = CountingPreviewBuilder()
        let controller = ShortsController(
            sourceURL: source, store: ProjectStore(baseDirectory: root), openRouterKeyStore: EmptyOpenRouterKeyStore(),
            previewBuilder: builder, preferences: PreviewPreferences())
        let candidate = ShortCandidate(
            id: UUID(), rank: 1, title: "Benchmark", reason: "", hook: "", pattern: "", excerpt: "",
            start: 0, end: 3, confidence: 1, hookScore: 10, standaloneScore: 10, payoffScore: 10, pacingScore: 10,
            enabled: true)
        controller.candidates = [candidate]
        controller.preview(candidate)
        try await wait { controller.player.currentItem?.status == .readyToPlay }
        let warm = CommandLine.arguments.contains("warm")
        if warm {
            let previous = controller.player.currentItem
            controller.subtitleHighlight.toggle()
            await Task.yield()
            try await wait { controller.player.currentItem !== previous && controller.player.currentItem?.status == .readyToPlay }
        }
        let beforeBuilds = builder.builds
        let start = ContinuousClock.now
        for _ in 0..<10 {
            let previous = controller.player.currentItem
            controller.subtitleHighlight.toggle()
            await Task.yield()
            try await wait { controller.player.currentItem !== previous && controller.player.currentItem?.status == .readyToPlay }
        }
        let elapsed = ContinuousClock.now - start
        let item = controller.player.currentItem!
        let duration = try await item.asset.load(.duration).seconds
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let result: [String: Any] = [
            "seconds": Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
            "appearanceChanges": 10, "builds": builder.builds - beforeBuilds, "warm": warm,
            "duration": duration, "frameWidth": controller.previewFrameSize?.width ?? 0,
            "frameHeight": controller.previewFrameSize?.height ?? 0, "peakRSSBytes": usage.ru_maxrss,
            "cpuSeconds": Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6,
        ]
        await controller.shutdown()
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: .sortedKeys), as: UTF8.self))
    }

    @MainActor
    static func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw CocoaError(.fileReadUnknown) }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}
