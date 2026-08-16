import Foundation
import Observation

func unavailableMediaSources(_ sources: [MediaReference]) -> [MediaReference] {
    sources.filter { $0.resolvedURL == nil }
}

@MainActor
@Observable
final class MediaAvailabilityMonitor {
    private(set) var missingSources: [MediaReference] = []
    var message: String?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = Generation()

    func check(sources: [MediaReference]) {
        task?.cancel()
        let current = generation.advance()
        missingSources = []
        message = nil
        task = Task { [weak self] in
            let missing = await Task.detached(priority: .utility) {
                unavailableMediaSources(sources)
            }.value
            guard let self, !Task.isCancelled, generation.isCurrent(current) else { return }
            missingSources = missing
            guard !missing.isEmpty else { return }
            let names = missing.map(\.displayName).joined(separator: ", ")
            message = "Не нашёл исходные файлы: \(names). Клипы сохранены — укажи, где теперь лежат файлы."
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        _ = generation.advance()
        missingSources = []
        message = nil
    }
}
