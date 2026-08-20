import Foundation
import Testing

@testable import MontazhkaKit

@Suite
struct WaveformStoreTests {
    @Test
    func testConcurrentRequestsForOneSourceDecodeOnce() async {
        let probe = WaveformLoaderProbe()
        let store = makeStore(probe: probe)

        await withTaskGroup(of: [Float]?.self) { group in
            for _ in 0..<20 { group.addTask { await store.ensure(path: "/tmp/shared.mov") } }
            for await result in group { #expect((result) == ([0.25, 0.5])) }
        }

        let startedCount = await probe.startedCount
        #expect((startedCount) == (1))
    }

    @Test
    func testDecodeConcurrencyIsBoundedToTwo() async {
        let probe = WaveformLoaderProbe()
        let store = makeStore(probe: probe)

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<10 {
                group.addTask { _ = await store.ensure(path: "/tmp/source-\(index).mov") }
            }
        }

        let maximumActive = await probe.maximumActive
        #expect((maximumActive) == (2))
    }

    @Test
    func testMemoryCountLimitDoesNotRetainEveryWaveform() async {
        let probe = WaveformLoaderProbe()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("waveform-limit-\(UUID().uuidString)")
        let store = WaveformStore(
            cacheDir: root, memoryCostLimit: 1_024,
            memoryCountLimit: 2, maxConcurrentDecodes: 2,
            loader: probe.load)

        for index in 0..<5 { _ = await store.ensure(path: "/tmp/cache-\(index).mov") }
        let retained = (0..<5).compactMap { store.peaks(for: "/tmp/cache-\($0).mov") }.count

        #expect((retained) <= (2))
    }

    private func makeStore(probe: WaveformLoaderProbe) -> WaveformStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("waveform-probe-\(UUID().uuidString)")
        return WaveformStore(cacheDir: root, maxConcurrentDecodes: 2, loader: probe.load)
    }
}

private actor WaveformLoaderProbe {
    private(set) var startedCount = 0
    private var active = 0
    private(set) var maximumActive = 0

    func load(path: String, cacheURL: URL) async -> [Float]? {
        startedCount += 1
        active += 1
        maximumActive = max(maximumActive, active)
        try? await Task.sleep(for: .milliseconds(20))
        active -= 1
        return [0.25, 0.5]
    }
}
