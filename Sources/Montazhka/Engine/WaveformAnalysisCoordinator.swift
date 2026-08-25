import Foundation
import Observation

@MainActor
@Observable
final class WaveformAnalysisCoordinator {
    var candidates: [PauseCandidate] = []
    private(set) var isDetecting = false
    private(set) var version = 0

    let store: WaveformStore
    @ObservationIgnored private var warmupTask: Task<Void, Never>?
    @ObservationIgnored private var detectionTask: Task<Void, Never>?
    @ObservationIgnored private var detectionGeneration = Generation()
    @ObservationIgnored private var analysisDetached: Task<[PauseCandidate], Never>?
    init(store: WaveformStore) {
        self.store = store
    }

    func warmUp(paths: [String]) {
        warmupTask?.cancel()
        let uniquePaths = Array(Set(paths))
        warmupTask = Task { [weak self, store] in
            await withTaskGroup(of: Bool.self) { group in
                for path in uniquePaths {
                    group.addTask { await store.ensure(path: path) != nil }
                }
                for await ready in group {
                    guard !Task.isCancelled else {
                        group.cancelAll()
                        return
                    }
                    if ready { self?.version += 1 }
                }
            }
        }
    }

    func detect(clips: [Clip], settings: DetectionSettings) {
        detectionTask?.cancel()
        analysisDetached?.cancel()
        let current = detectionGeneration.advance()
        isDetecting = true
        detectionTask = Task { [weak self, store] in
            await withTaskGroup(of: Void.self) { group in
                for path in Set(clips.map(\.sourcePath)) {
                    group.addTask { await store.ensure(path: path) }
                }
            }
            guard let self, !Task.isCancelled, detectionGeneration.isCurrent(current) else { return }
            // Отдельный unstructured-таск: отмена в него сама не протекает,
            // поэтому хэндл храним и отменяем явно.
            let detached = Task.detached(priority: .userInitiated) {
                SilenceDetector.findPauses(
                    clips: clips,
                    peaksFor: { store.peaks(for: $0) },
                    settings: settings
                )
            }
            analysisDetached = detached
            let found = await detached.value
            guard !Task.isCancelled, detectionGeneration.isCurrent(current) else { return }
            version += 1
            candidates = found
            isDetecting = false
        }
    }

    func cancel() {
        warmupTask?.cancel()
        detectionTask?.cancel()
        warmupTask = nil
        detectionTask = nil
        analysisDetached?.cancel()
        analysisDetached = nil
        _ = detectionGeneration.advance()
        isDetecting = false
    }

    func clearCandidates() { candidates = [] }
}
