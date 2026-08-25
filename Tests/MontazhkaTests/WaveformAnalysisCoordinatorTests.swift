import Foundation
import Testing

@testable import MontazhkaKit

@Suite
struct WaveformAnalysisCoordinatorTests {
    /// Синтетические пики: 1 с громко, 2 с тишиной, 1 с громко (окна по 10 мс).
    private static let quietGapPeaks =
        [Float](repeating: 0.9, count: 100)
        + [Float](repeating: 0.001, count: 200)
        + [Float](repeating: 0.9, count: 100)

    /// Две тихие зоны: 1 с громко, 1 с тишиной, 1 с громко, 1 с тишиной, 1 с громко.
    private static let twoGapsPeaks =
        [Float](repeating: 0.9, count: 100)
        + [Float](repeating: 0.001, count: 100)
        + [Float](repeating: 0.9, count: 100)
        + [Float](repeating: 0.001, count: 100)
        + [Float](repeating: 0.9, count: 100)

    @MainActor
    @Test
    func testWarmUpRaisesVersionOnlyForReadyPaths() async {
        let store = makeStore(peaksByPath: [
            "/tmp/ready.mov": Self.quietGapPeaks
        ])
        let coordinator = WaveformAnalysisCoordinator(store: store)

        coordinator.warmUp(paths: ["/tmp/ready.mov", "/tmp/missing.mov"])

        let warmed = await waitUntil(timeout: .seconds(2)) { coordinator.version >= 1 }
        #expect(warmed, "Готовый путь не поднял version")
        // Даём группе довершить обработку непопадающего пути и убеждаемся,
        // что версия не увеличилась от него.
        try? await Task.sleep(for: .milliseconds(200))
        #expect(coordinator.version == 1, "Version подрос от недоступного пути")
    }

    @MainActor
    @Test
    func testDetectReturnsSilenceCandidatesForQuietGap() async {
        let store = makeStore(peaksByPath: ["/tmp/gap.mov": Self.quietGapPeaks])
        let coordinator = WaveformAnalysisCoordinator(store: store)
        let clip = Clip(sourcePath: "/tmp/gap.mov", start: 0, end: 4)

        coordinator.detect(clips: [clip], settings: DetectionSettings())

        let detected = await waitUntil(timeout: .seconds(5)) {
            !coordinator.candidates.isEmpty && !coordinator.isDetecting
        }
        #expect(detected, "Детект не вернул кандидатов")
        #expect(coordinator.candidates.count == 1)
        guard let candidate = coordinator.candidates.first else { return }
        // Тишина 1.0–3.0 с: с отступами 150 мс границы вырезки 1.15–2.85.
        #expect(abs((candidate.fullStart) - (1.0)) <= (0.001))
        #expect(abs((candidate.fullEnd) - (3.0)) <= (0.001))
        #expect(abs((candidate.start) - (1.15)) <= (0.001))
        #expect(abs((candidate.end) - (2.85)) <= (0.001))
    }

    @MainActor
    @Test
    func testDetectOnMissingSourceLeavesCandidatesEmpty() async {
        let store = makeStore(peaksByPath: [:])
        let coordinator = WaveformAnalysisCoordinator(store: store)

        coordinator.detect(
            clips: [Clip(sourcePath: "/tmp/absent.mov", start: 0, end: 4)],
            settings: DetectionSettings())

        let finished = await waitUntil(timeout: .seconds(3)) { !coordinator.isDetecting }
        #expect(finished, "Детект по отсутствующему файлу не завершился")
        #expect(coordinator.candidates.isEmpty)
        // Детект завершился штатно: version растёт всегда, кандидатов нет.
        #expect(coordinator.version == 1)
    }

    @MainActor
    @Test
    func testSecondDetectSupersedesFirstGeneration() async {
        let store = makeStore(peaksByPath: [
            "/tmp/slow.mov": Self.quietGapPeaks,
            "/tmp/fast.mov": Self.twoGapsPeaks,
        ])
        let coordinator = WaveformAnalysisCoordinator(store: store)

        // Первый детект: единственная тихая зона (медленный loader).
        coordinator.detect(
            clips: [Clip(sourcePath: "/tmp/slow.mov", start: 0, end: 4)],
            settings: DetectionSettings())
        // Второй детект сразу же: две тихие зоны (быстрый loader).
        coordinator.detect(
            clips: [Clip(sourcePath: "/tmp/fast.mov", start: 0, end: 5)],
            settings: DetectionSettings())

        let detected = await waitUntil(timeout: .seconds(5)) {
            coordinator.candidates.count == 2 && !coordinator.isDetecting
        }
        #expect(detected, "Финальным должен быть результат последнего детекта")
        #expect(!coordinator.candidates.isEmpty)
        // Границы двух пауз: 1.0–2.0 и 3.0–4.0 (с отступами 150 мс — 1.15–1.85 и 3.15–3.85).
        guard let first = coordinator.candidates.first, let last = coordinator.candidates.last else {
            return
        }
        #expect(abs((first.fullStart) - (1.0)) <= (0.001))
        #expect(abs((first.fullEnd) - (2.0)) <= (0.001))
        #expect(abs((last.fullStart) - (3.0)) <= (0.001))
        #expect(abs((last.fullEnd) - (4.0)) <= (0.001))
        // Ни один кандидат не принадлежит отменённой генерации (одна зона 1.0–3.0).
        for candidate in coordinator.candidates {
            #expect(!(abs((candidate.fullStart) - (1.0)) <= (0.001) && abs((candidate.fullEnd) - (3.0)) <= (0.001)))
        }
    }

    // MARK: - Помощники

    @MainActor
    private func waitUntil(
        timeout: Duration,
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func makeStore(peaksByPath: [String: [Float]]) -> WaveformStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("waveform-coordinator-\(UUID().uuidString)")
        return WaveformStore(
            cacheDir: root, maxConcurrentDecodes: 2,
            loader: { path, _ in
                if path.hasSuffix("slow.mov") {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                return peaksByPath[path]
            })
    }
}
