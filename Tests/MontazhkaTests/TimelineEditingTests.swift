import Foundation
import Testing

@testable import MontazhkaKit

@Suite
struct TimelineEditingTests {
    @MainActor
    @Test
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

        let loadCount = await keyStore.loadCount
        #expect((loadCount) == (1))
        #expect((controller.openRouterKeyStatus) == (.missing))
        await controller.shutdown()
    }

    @Test
    func testShorteningClipPreservesIdentityAndShortensLeftEdge() {
        let target = Clip(sourcePath: "/tmp/one.mov", start: 2, end: 8)
        let neighbor = Clip(sourcePath: "/tmp/two.mov", start: 0, end: 3)

        let result = TimelineOps.shorteningClip(
            clips: [target, neighbor], id: target.id, edge: .start, sourceTime: 3.5
        )

        #expect((result[0].id) == (target.id))
        #expect(abs((result[0].start) - (3.5)) <= (0.0001))
        #expect(abs((result[0].end) - (8)) <= (0.0001))
        #expect((result[1]) == (neighbor))
        #expect(abs((result.reduce(0) { $0 + $1.duration }) - (7.5)) <= (0.0001))
    }

    @Test
    func testShorteningClipRejectsExpansionAndTooSmallResult() {
        let clip = Clip(sourcePath: "/tmp/one.mov", start: 2, end: 8)

        #expect(
            (TimelineOps.shorteningClip(
                clips: [clip], id: clip.id, edge: .end, sourceTime: 9
            )) == ([clip]))
        #expect(
            (TimelineOps.shorteningClip(
                clips: [clip], id: clip.id, edge: .start, sourceTime: 7.95
            )) == ([clip]))

        let shortened = TimelineOps.shorteningClip(
            clips: [clip], id: clip.id, edge: .end, sourceTime: 5
        )
        #expect(abs((shortened[0].start) - (2)) <= (0.0001))
        #expect(abs((shortened[0].end) - (5)) <= (0.0001))
    }

    @MainActor
    @Test
    func testCommitTrimIsOneUndoableEditAndClearsRangeSelection() async {
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

        #expect(abs((controller.project.clips[0].end) - (7)) <= (0.0001))
        #expect((controller.selectedClipID) == (clip.id))
        #expect((controller.timelineSelection) == nil)
        #expect(abs((controller.currentTime) - (7)) <= (0.0001))
        #expect(controller.canUndo)

        controller.undo()
        #expect((controller.project.clips[0]) == (clip))
        await controller.shutdown()
    }

    @Test
    func testSelectionNormalizesAndClampsToTimeline() {
        let selection = TimelineSelection(start: 8, end: -2, duration: 6)

        #expect((selection?.start) == (0))
        #expect((selection?.end) == (6))
        #expect((selection?.duration) == (6))
    }

    @Test
    func testSelectionRejectsAccidentalTinyRange() {
        #expect((TimelineSelection(start: 2, end: 2.03, duration: 10)) == nil)
    }

    @MainActor
    @Test
    func testUndoRestoresProjectSettingsAsOneDocumentSnapshot() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-editor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = EditorController(
            project: Project(name: "История"),
            store: ProjectStore(baseDirectory: root),
            openRouterKeyStore: EmptyOpenRouterKeyStore())
        var changed = MusicSettings()
        changed.enabled = true
        changed.volume = 42

        controller.updateMusicSettings(changed)
        controller.undo()

        #expect((controller.project.music) == (MusicSettings()))
        await controller.shutdown()
    }

    @MainActor
    @Test
    func testUnreadableVideoReportsImportFailureInsteadOfLeavingEmptyTimelineSilently() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-import-error-\(UUID().uuidString)", isDirectory: true)
        let brokenVideo = root.appendingPathComponent("broken.mov")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not a movie".utf8).write(to: brokenVideo)
        let controller = EditorController(
            project: Project(name: "Импорт"),
            store: ProjectStore(baseDirectory: root),
            openRouterKeyStore: EmptyOpenRouterKeyStore())

        controller.addClips(urls: [brokenVideo])
        for _ in 0..<100 {
            if case .failed = controller.clipImportState { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        guard case .failed(let message) = controller.clipImportState else {
            Issue.record("Импорт должен завершиться понятной ошибкой")
            return
        }
        #expect(message.contains("broken.mov"))
        #expect(controller.project.clips.isEmpty)
        await controller.shutdown()
    }

    @MainActor
    @Test
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
        let controller = EditorController(
            project: Project(name: "Закрытие", clips: clips),
            store: ProjectStore(baseDirectory: root),
            openRouterKeyStore: EmptyOpenRouterKeyStore())

        await controller.shutdown()
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect((controller.player.currentItem) == nil)
        #expect((controller.previewState) == (.empty))
    }
}

private actor RecordingOpenRouterKeyStore: OpenRouterKeyStoring {
    private(set) var loadCount = 0

    func load() throws -> String? {
        loadCount += 1
        return nil
    }

    func save(_ key: String) throws {}
    func delete() throws {}
}
