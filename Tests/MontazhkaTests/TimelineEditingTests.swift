import Foundation
import XCTest
@testable import Montazhka

final class TimelineEditingTests: XCTestCase {
    @MainActor
    func testControllerUsesInjectedOpenRouterKeyStore() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-key-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let keyStore = RecordingOpenRouterKeyStore()
        let controller = EditorController(
            project: Project(name: "Без системного Keychain"),
            store: ProjectStore(baseDirectory: root),
            openRouterKeyStore: keyStore
        )

        for _ in 0..<50 where controller.openRouterKeyStatus == .checking {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(keyStore.loadCount, 1)
        XCTAssertEqual(controller.openRouterKeyStatus, .missing)
        controller.shutdown()
    }

    func testShorteningClipPreservesIdentityAndShortensLeftEdge() {
        let target = Clip(sourcePath: "/tmp/one.mov", start: 2, end: 8)
        let neighbor = Clip(sourcePath: "/tmp/two.mov", start: 0, end: 3)

        let result = TimelineOps.shorteningClip(
            clips: [target, neighbor], id: target.id, edge: .start, sourceTime: 3.5
        )

        XCTAssertEqual(result[0].id, target.id)
        XCTAssertEqual(result[0].start, 3.5, accuracy: 0.0001)
        XCTAssertEqual(result[0].end, 8, accuracy: 0.0001)
        XCTAssertEqual(result[1], neighbor)
        XCTAssertEqual(result.reduce(0) { $0 + $1.duration }, 7.5, accuracy: 0.0001)
    }

    func testShorteningClipRejectsExpansionAndTooSmallResult() {
        let clip = Clip(sourcePath: "/tmp/one.mov", start: 2, end: 8)

        XCTAssertEqual(
            TimelineOps.shorteningClip(
                clips: [clip], id: clip.id, edge: .end, sourceTime: 9
            ),
            [clip]
        )
        XCTAssertEqual(
            TimelineOps.shorteningClip(
                clips: [clip], id: clip.id, edge: .start, sourceTime: 7.95
            ),
            [clip]
        )

        let shortened = TimelineOps.shorteningClip(
            clips: [clip], id: clip.id, edge: .end, sourceTime: 5
        )
        XCTAssertEqual(shortened[0].start, 2, accuracy: 0.0001)
        XCTAssertEqual(shortened[0].end, 5, accuracy: 0.0001)
    }

    @MainActor
    func testCommitTrimIsOneUndoableEditAndClearsRangeSelection() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-trim-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let clip = Clip(sourcePath: "/tmp/trim.mov", start: 0, end: 10)
        let controller = EditorController(
            project: Project(name: "Обрезка", clips: [clip]),
            store: ProjectStore(baseDirectory: root),
            openRouterKeyStore: EmptyOpenRouterKeyStore()
        )
        controller.selectedClipID = clip.id
        controller.setSelection(start: 1, end: 2)

        controller.commitTrim(clipID: clip.id, edge: .end, sourceTime: 7)

        XCTAssertEqual(controller.project.clips[0].end, 7, accuracy: 0.0001)
        XCTAssertEqual(controller.selectedClipID, clip.id)
        XCTAssertNil(controller.timelineSelection)
        XCTAssertEqual(controller.currentTime, 7, accuracy: 0.0001)
        XCTAssertTrue(controller.canUndo)

        controller.undo()
        XCTAssertEqual(controller.project.clips[0], clip)
        controller.shutdown()
    }

    func testSelectionNormalizesAndClampsToTimeline() {
        let selection = TimelineSelection(start: 8, end: -2, duration: 6)

        XCTAssertEqual(selection?.start, 0)
        XCTAssertEqual(selection?.end, 6)
        XCTAssertEqual(selection?.duration, 6)
    }

    func testSelectionRejectsAccidentalTinyRange() {
        XCTAssertNil(TimelineSelection(start: 2, end: 2.03, duration: 10))
    }

    @MainActor
    func testUndoRestoresProjectSettingsAsOneDocumentSnapshot() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-editor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = EditorController(project: Project(name: "История"),
                                          store: ProjectStore(baseDirectory: root),
                                          openRouterKeyStore: EmptyOpenRouterKeyStore())
        var changed = MusicSettings()
        changed.enabled = true
        changed.volume = 42

        controller.updateMusicSettings(changed)
        controller.undo()

        XCTAssertEqual(controller.project.music, MusicSettings())
        controller.shutdown()
    }

    @MainActor
    func testUnreadableVideoReportsImportFailureInsteadOfLeavingEmptyTimelineSilently() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-import-error-\(UUID().uuidString)", isDirectory: true)
        let brokenVideo = root.appendingPathComponent("broken.mov")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not a movie".utf8).write(to: brokenVideo)
        let controller = EditorController(project: Project(name: "Импорт"),
                                          store: ProjectStore(baseDirectory: root),
                                          openRouterKeyStore: EmptyOpenRouterKeyStore())

        controller.addClips(urls: [brokenVideo])
        for _ in 0..<100 {
            if case .failed = controller.clipImportState { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        guard case .failed(let message) = controller.clipImportState else {
            return XCTFail("Импорт должен завершиться понятной ошибкой")
        }
        XCTAssertTrue(message.contains("broken.mov"))
        XCTAssertTrue(controller.project.clips.isEmpty)
        controller.shutdown()
    }

    @MainActor
    func testShutdownCancelsPreparationAndReleasesPlayerItem() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-shutdown-\(UUID().uuidString)", isDirectory: true)
        let video = root.appendingPathComponent("source.mov")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await TestVideoFactory.make(segments: [(duration: 3, loud: true)], to: video)
        let source = MediaReference(url: video)
        let clips = (0..<80).map { index in
            Clip(source: source, start: Double(index) * 0.03, end: Double(index + 1) * 0.03)
        }
        let controller = EditorController(project: Project(name: "Закрытие", clips: clips),
                                          store: ProjectStore(baseDirectory: root),
                                          openRouterKeyStore: EmptyOpenRouterKeyStore())

        controller.shutdown()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNil(controller.player.currentItem)
        XCTAssertEqual(controller.previewState, .empty)
    }
}

private final class RecordingOpenRouterKeyStore: OpenRouterKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var loads = 0

    var loadCount: Int {
        lock.withLock { loads }
    }

    func load() throws -> String? {
        lock.withLock { loads += 1 }
        return nil
    }

    func save(_ key: String) throws {}
    func delete() throws {}
}
