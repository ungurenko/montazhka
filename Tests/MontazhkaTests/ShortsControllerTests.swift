import AVFoundation
import Foundation
import Testing

@testable import MontazhkaKit

@Suite
@MainActor
struct ShortsControllerTests {
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

@MainActor
private final class ControlledShortsPreviewBuilder: ShortsPreviewBuilding {
    private var continuations: [UUID: CheckedContinuation<AVPlayerItem, Error>] = [:]

    var pendingIDs: Set<UUID> { Set(continuations.keys) }

    func makeItem(for request: ShortsPreviewRequest) async throws -> AVPlayerItem {
        try await withCheckedThrowingContinuation { continuation in
            continuations[request.candidateID] = continuation
        }
    }

    func complete(_ id: UUID, with url: URL) {
        continuations.removeValue(forKey: id)?.resume(returning: AVPlayerItem(url: url))
    }
}
