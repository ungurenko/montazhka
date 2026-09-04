import AVFoundation
import Foundation
import Testing

@testable import MontazhkaKit

@Suite
@MainActor
struct ShortsControllerTests {
    @Test
    func controllersLoadAndSaveOnlyThroughInjectedPreferences() async throws {
        let root = temporaryDirectory("injected-preferences")
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = ControllerPreferenceStore()
        ShortsCount.eight.save(in: preferences)
        SmartEditModel.luna.save(in: preferences)
        ReasoningChoice.effort(.high).save(
            key: ShortsController.reasoningKey,
            in: preferences)
        var savedAppearance = ShortsSubtitlePreset.plate.appearance
        savedAppearance.size = .large
        ShortsSubtitleSettings(
            enabled: true, appearance: savedAppearance, highlightActiveWord: true
        )
        .save(in: preferences)

        let repository = ProjectStore(baseDirectory: root)
        let shorts = ShortsController(
            sourceURL: root.appendingPathComponent("source.mov"),
            store: repository,
            openRouterKeyStore: EmptyOpenRouterKeyStore(),
            previewBuilder: ControlledShortsPreviewBuilder(),
            preferences: preferences)
        let editor = EditorController(
            project: Project(name: "Тест"),
            store: repository,
            openRouterKeyStore: EmptyOpenRouterKeyStore(),
            preferences: preferences)

        #expect(shorts.count == .eight)
        #expect(shorts.aiConnection.modelID == SmartEditModel.luna.rawValue)
        #expect(shorts.aiConnection.reasoningChoice == .effort(.high))
        #expect(shorts.subtitlesEnabled)
        #expect(shorts.subtitleBackground == .plate)
        #expect(shorts.subtitleSize == .large)
        #expect(editor.aiConnection.modelID == SmartEditModel.luna.rawValue)

        shorts.count = .three
        shorts.subtitlePreset = .accent
        #expect(ShortsCount.saved(in: preferences) == .three)
        #expect(
            ShortsSubtitleSettings.saved(in: preferences).appearance
                == ShortsSubtitlePreset.accent.appearance)

        await shorts.shutdown()
        await editor.shutdown()
    }

    @Test
    func previewRequestCarriesSelectedFrameModeAndCanvasColor() async throws {
        let root = temporaryDirectory("preview-format")
        defer { try? FileManager.default.removeItem(at: root) }
        let builder = ControlledShortsPreviewBuilder()
        let controller = ShortsController(
            sourceURL: root.appendingPathComponent("source.mov"),
            store: ProjectStore(baseDirectory: root),
            openRouterKeyStore: EmptyOpenRouterKeyStore(),
            previewBuilder: builder
        )
        let item = candidate(title: "Формат")
        controller.frameMode = .verticalFit
        controller.canvasColor = .white

        controller.preview(item)
        try await waitUntil { builder.requests[item.id] != nil }

        #expect(
            builder.requests[item.id]?.frameSettings
                == ShortsFrameSettings(mode: .verticalFit, canvasColor: .white))
        await controller.shutdown()
    }

    @Test
    func currentPreviewFailureIsVisibleToUser() async throws {
        let root = temporaryDirectory("preview-error")
        defer { try? FileManager.default.removeItem(at: root) }
        let builder = ControlledShortsPreviewBuilder()
        let controller = ShortsController(
            sourceURL: root.appendingPathComponent("source.mov"),
            store: ProjectStore(baseDirectory: root),
            openRouterKeyStore: EmptyOpenRouterKeyStore(),
            previewBuilder: builder
        )
        let item = candidate(title: "Ошибка")

        controller.preview(item)
        try await waitUntil { builder.pendingIDs.contains(item.id) }
        builder.fail(item.id, with: ShortsVideoCompositionError.invalidVideoTrack)
        try await waitUntil { controller.previewError != nil }

        #expect(controller.previewError?.message.contains("Не удалось подготовить вертикальный кадр") == true)
        await controller.shutdown()
    }

    @Test
    func latestPreviewWinsWhenOlderCropFinishesLast() async throws {
        let root = temporaryDirectory("latest-preview")
        defer { try? FileManager.default.removeItem(at: root) }
        let builder = ControlledShortsPreviewBuilder()
        let controller = ShortsController(
            sourceURL: root.appendingPathComponent("source.mov"),
            store: ProjectStore(baseDirectory: root),
            openRouterKeyStore: EmptyOpenRouterKeyStore(),
            previewBuilder: builder
        )
        let first = candidate(title: "Первый")
        let second = candidate(title: "Второй")

        controller.preview(first)
        try await waitUntil { builder.pendingIDs.contains(first.id) }
        controller.preview(second)
        try await waitUntil { builder.pendingIDs.contains(second.id) }

        let secondURL = root.appendingPathComponent("second.mov")
        builder.complete(second.id, with: secondURL)
        try await waitUntil { currentAssetURL(controller) == secondURL }

        let firstURL = root.appendingPathComponent("first.mov")
        builder.complete(first.id, with: firstURL)
        try await Task.sleep(for: .milliseconds(30))

        #expect(currentAssetURL(controller) == secondURL)
        await controller.shutdown()
    }

    @Test
    func shutdownCancelsPendingPreviewBeforeItCanTouchPlayer() async throws {
        let root = temporaryDirectory("preview-shutdown")
        defer { try? FileManager.default.removeItem(at: root) }
        let builder = ControlledShortsPreviewBuilder()
        let controller = ShortsController(
            sourceURL: root.appendingPathComponent("source.mov"),
            store: ProjectStore(baseDirectory: root),
            openRouterKeyStore: EmptyOpenRouterKeyStore(),
            previewBuilder: builder
        )
        let item = candidate(title: "Отменённый")

        controller.preview(item)
        try await waitUntil { builder.pendingIDs.contains(item.id) }
        await controller.shutdown()
        builder.complete(item.id, with: root.appendingPathComponent("late.mov"))
        try await Task.sleep(for: .milliseconds(30))

        #expect(controller.player.currentItem == nil)
        #expect(!controller.isPlaying)
    }

    private func candidate(title: String) -> ShortCandidate {
        ShortCandidate(
            id: UUID(), rank: 1, title: title, reason: "", hook: "", pattern: "",
            excerpt: "", start: 0, end: 5, confidence: 1,
            hookScore: 10, standaloneScore: 10, payoffScore: 10, pacingScore: 10,
            enabled: true
        )
    }

    private func temporaryDirectory(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-\(suffix)-\(UUID().uuidString)", isDirectory: true)
    }

    private func currentAssetURL(_ controller: ShortsController) -> URL? {
        (controller.player.currentItem?.asset as? AVURLAsset)?.url
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Асинхронная операция не завершилась вовремя")
    }
}

private final class ControllerPreferenceStore: PreferenceStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var strings: [String: String] = [:]
    private var bools: [String: Bool] = [:]

    func string(forKey key: String) -> String? {
        lock.withLock { strings[key] }
    }

    func set(_ value: String?, forKey key: String) {
        lock.withLock { strings[key] = value }
    }

    func bool(forKey key: String) -> Bool {
        lock.withLock { bools[key] ?? false }
    }

    func set(_ value: Bool, forKey key: String) {
        lock.withLock { bools[key] = value }
    }
}

@MainActor
private final class ControlledShortsPreviewBuilder: ShortsPreviewBuilding {
    private var continuations: [UUID: CheckedContinuation<ShortsPreviewItem, Error>] = [:]
    private(set) var requests: [UUID: ShortsPreviewRequest] = [:]

    var pendingIDs: Set<UUID> { Set(continuations.keys) }

    func makeItem(for request: ShortsPreviewRequest) async throws -> ShortsPreviewItem {
        requests[request.candidateID] = request
        return try await withCheckedThrowingContinuation { continuation in
            continuations[request.candidateID] = continuation
        }
    }

    func complete(_ id: UUID, with url: URL) {
        continuations.removeValue(forKey: id)?
            .resume(
                returning: ShortsPreviewItem(
                    item: AVPlayerItem(url: url),
                    frameSize: CGSize(width: 1080, height: 1920)))
    }

    func fail(_ id: UUID, with error: any Error) {
        continuations.removeValue(forKey: id)?.resume(throwing: error)
    }
}
