import Foundation
import Observation

/// Пересчитывает голос, сохраняя прежний готовый звук до завершения нового запуска.
@MainActor
@Observable
final class EditorVoiceEnhancementCoordinator {
    private(set) var status: VoiceEnhanceStatus = .idle
    @ObservationIgnored private(set) var readyAudio: [String: URL] = [:]

    private let store: VoiceEnhanceStore
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var generation = Generation()

    init(store: VoiceEnhanceStore) {
        self.store = store
    }

    func refresh(
        settings: VoiceEnhanceSettings, sources: [String],
        rebuildPreview: @escaping @MainActor () -> Void
    ) {
        let current = generation.advance()
        renderTask?.cancel()

        guard settings.enabled else {
            resetReadyAudio()
            rebuildPreview()
            renderTask = Task { [store] in await store.cancelAll() }
            return
        }

        guard !sources.isEmpty else {
            status = .idle
            renderTask = Task { [store] in await store.cancelAll() }
            return
        }
        status = .rendering(done: 0, total: sources.count)

        renderTask = Task { [weak self] in
            guard let self else { return }
            await self.store.cancelAll()
            guard !Task.isCancelled, self.generation.isCurrent(current) else { return }
            guard let ready = await self.render(sources: sources, settings: settings, generation: current) else {
                return
            }
            guard !Task.isCancelled, self.generation.isCurrent(current) else { return }
            self.readyAudio = ready
            self.status = .idle
            rebuildPreview()
            self.renderTask = nil
        }
    }

    /// Смена версии проекта без улучшения: сбрасывает только готовый звук и статус.
    func resetReadyAudio() {
        readyAudio = [:]
        status = .idle
    }

    /// Рендеры самого store останавливает редактор в прежнем порядке закрытия.
    func cancel() {
        renderTask?.cancel()
        _ = generation.advance()
    }

    private func render(
        sources: [String], settings: VoiceEnhanceSettings, generation current: Int
    ) async -> [String: URL]? {
        var ready: [String: URL] = [:]
        for (index, path) in sources.enumerated() {
            do {
                ready[path] = try await store.ensure(source: path, settings: settings)
            } catch is CancellationError {
                return nil
            } catch VoiceEnhanceError.noAudioTrack {
                // Без звуковой дорожки — оставляем оригинал.
            } catch {
                guard generation.isCurrent(current) else { return nil }
                status = .failed(
                    UserFacingError(
                        "Не получилось обработать звук.",
                        hint: "Просмотр и экспорт пойдут с исходным звуком."))
                readyAudio = [:]
                return nil
            }
            guard generation.isCurrent(current) else { return nil }
            status = .rendering(done: index + 1, total: sources.count)
        }
        guard generation.isCurrent(current) else { return nil }
        return ready
    }
}
