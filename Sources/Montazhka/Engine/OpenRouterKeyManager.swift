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
            let result: OpenRouterKeyStatus
            do {
                result = try await store.load() == nil ? .missing : .saved
            } catch {
                result = .failed(error.localizedDescription)
            }
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
            try await store.save(trimmed)
            status = .saved
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func validateSaved() async {
        do {
            guard let key = try await store.load() else {
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

    func delete() async -> Bool {
        do {
            try await store.delete()
            status = .missing
            return true
        } catch {
            status = .failed(error.localizedDescription)
            return false
        }
    }

    func load() async throws -> String? { try await store.load() }

    func cancel() {
        refreshTask?.cancel()
        refreshTask = nil
    }
}
