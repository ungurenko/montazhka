import AVFoundation
import Foundation
import Testing

@testable import MontazhkaKit

@Suite
@MainActor
struct ShortsControllerTests {
    @Test
    func appearanceChangesReuseReadyPlanWithFreshPlayerItems() async throws {
        let root = temporaryDirectory("preview-reuse")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("source.mov")
        try await TestVideoFactory.make(segments: [(duration: 5, loud: false)], to: url)
        let builder = ControlledShortsPreviewBuilder()
        let words = [TranscriptWord(sourceID: UUID(), text: "Latest", start: 0, end: 1, confidence: 1)]
        let controller = ShortsController(
            sourceURL: url, store: ProjectStore(baseDirectory: root), openRouterKeyStore: EmptyOpenRouterKeyStore(),
            previewBuilder: builder, preferences: ControllerPreferenceStore(), initialTranscriptWords: words)
        controller.subtitlesEnabled = true
        let item = candidate(title: "Reuse")
        controller.candidates = [item]
        controller.preview(item)
        try await waitUntil { builder.pendingIDs.contains(item.id) }
        builder.complete(item.id, with: url)
        try await waitUntil { controller.player.currentItem != nil }
        let first = controller.player.currentItem
        for _ in 0..<10 {
            controller.currentTime = 3
            controller.subtitleHighlight.toggle()
            #expect(controller.currentTime == 0)
            #expect(controller.player.currentItem !== first)
            #expect(controller.previewFrameSize == CGSize(width: 1080, height: 1920))
            #expect(controller.currentPreviewSubtitle?.words == ["Latest"])
            #expect(controller.currentPreviewSubtitle?.activeWordIndex == (controller.subtitleHighlight ? 0 : nil))
        }
        #expect(builder.callCount == 1)
        #expect(builder.pendingIDs.isEmpty)
        await controller.shutdown()
    }

    @Test
    func pendingAppearanceChangesShareOneBuildAndGeometryInvalidates() async throws {
        let root = temporaryDirectory("preview-pending-reuse")
        defer { try? FileManager.default.removeItem(at: root) }
        let builder = ControlledShortsPreviewBuilder()
        let controller = ShortsController(
            sourceURL: root.appendingPathComponent("source.mov"), store: ProjectStore(baseDirectory: root),
            openRouterKeyStore: EmptyOpenRouterKeyStore(), previewBuilder: builder,
            preferences: ControllerPreferenceStore())
        let item = candidate(title: "Pending")
        controller.candidates = [item]
        controller.preview(item)
        try await waitUntil { builder.pendingIDs.contains(item.id) }
        for _ in 0..<10 { controller.subtitlesEnabled.toggle() }
        await Task.yield()
        #expect(builder.callCount == 1)
        builder.complete(item.id, with: root.appendingPathComponent("first.mov"))
        try await waitUntil { controller.player.currentItem != nil }
        controller.frameMode = .verticalFit
        try await waitUntil { builder.callCount == 2 }
        #expect(builder.requests[item.id]?.frameSettings.mode == .verticalFit)
        builder.complete(item.id, with: root.appendingPathComponent("second.mov"))
        try await waitUntil { currentAssetURL(controller) == root.appendingPathComponent("second.mov") }
        await controller.shutdown()
    }

    @Test
    func sourceFingerprintAndTimeMapChangesInvalidateThePlan() async throws {
        let root = temporaryDirectory("preview-key")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("source.mov")
        try Data([0]).write(to: url)
        let builder = ControlledShortsPreviewBuilder()
        let controller = ShortsController(
            sourceURL: url, store: ProjectStore(baseDirectory: root), openRouterKeyStore: EmptyOpenRouterKeyStore(),
            previewBuilder: builder, preferences: ControllerPreferenceStore())
        var item = candidate(title: "Key")
        item.segments = [ShortsSegment(start: 0, end: 2), ShortsSegment(start: 3, end: 5)]
        controller.candidates = [item]
        controller.preview(item)
        try await waitUntil { builder.callCount == 1 }
        builder.complete(item.id, with: url)
        try await waitUntil { controller.player.currentItem != nil }
        controller.trimPauses.toggle()
        try await waitUntil { builder.callCount == 2 }
        #expect(builder.requests[item.id]?.timeMap.outputDuration == 5)
        builder.complete(item.id, with: url)
        try await waitUntil { controller.previewFrameSize != nil }
        try Data([0, 1]).write(to: url)
        controller.subtitleHighlight.toggle()
        try await waitUntil { builder.callCount == 3 }
        builder.complete(item.id, with: url)
        try await waitUntil { controller.previewFrameSize != nil }
        await controller.shutdown()
    }

    @Test
    func failedBuildCanBeRetriedForTheSameKey() async throws {
        let root = temporaryDirectory("preview-retry")
        defer { try? FileManager.default.removeItem(at: root) }
        let builder = ControlledShortsPreviewBuilder()
        let controller = ShortsController(
            sourceURL: root.appendingPathComponent("source.mov"), store: ProjectStore(baseDirectory: root),
            openRouterKeyStore: EmptyOpenRouterKeyStore(), previewBuilder: builder,
            preferences: ControllerPreferenceStore())
        let item = candidate(title: "Retry")
        controller.preview(item)
        try await waitUntil { builder.callCount == 1 }
        builder.fail(item.id, with: ShortsVideoCompositionError.invalidVideoTrack)
        try await waitUntil { controller.previewError != nil }
        controller.preview(item)
        try await waitUntil { builder.callCount == 2 }
        builder.complete(item.id, with: root.appendingPathComponent("ready.mov"))
        try await waitUntil { controller.player.currentItem != nil }
        #expect(controller.previewError == nil)
        await controller.shutdown()
    }

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
    private(set) var callCount = 0

    var pendingIDs: Set<UUID> { Set(continuations.keys) }

    func makeItem(for request: ShortsPreviewRequest) async throws -> ShortsPreviewItem {
        callCount += 1
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
