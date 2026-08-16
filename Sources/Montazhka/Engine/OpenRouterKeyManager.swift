import Foundation
import Observation

@MainActor
@Observable
final class OpenRouterKeyManager {
    private(set) var status: OpenRouterKeyStatus = .missing

    private let store: any OpenRouterKeyStoring
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(store: any OpenRouterKeyStoring) {
        self.store = store
    }

    func refresh() {
        refreshTask?.cancel()
        status = .checking
        let store = self.store
        refreshTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                do {
                    return try store.load() == nil
                        ? OpenRouterKeyStatus.missing
                        : OpenRouterKeyStatus.saved
                } catch {
                    return OpenRouterKeyStatus.failed(error.localizedDescription)
                }
            }.value
            guard !Task.isCancelled else { return }
            self?.status = result
        }
    }

    func saveAndValidate(_ key: String) async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            status = .failed("Вставь ключ OpenRouter.")
            return
        }
        status = .checking
        do {
            try await OpenRouterClient().validateKey(trimmed)
            try store.save(trimmed)
            status = .saved
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func validateSaved() async {
        do {
            guard let key = try store.load() else {
                status = .missing
                return
            }
            status = .checking
            try await OpenRouterClient().validateKey(key)
            status = .saved
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func delete() -> Bool {
        do {
            try store.delete()
            status = .missing
            return true
        } catch {
            status = .failed(error.localizedDescription)
            return false
        }
    }

    func load() throws -> String? { try store.load() }

    func cancel() {
        refreshTask?.cancel()
        refreshTask = nil
    }
}
