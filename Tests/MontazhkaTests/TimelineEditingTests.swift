import Foundation
import XCTest
@testable import Montazhka

final class TimelineEditingTests: XCTestCase {
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
                                          store: ProjectStore(baseDirectory: root))
        var changed = MusicSettings()
        changed.enabled = true
        changed.volume = 42

        controller.updateMusicSettings(changed)
        controller.undo()

        XCTAssertEqual(controller.project.music, MusicSettings())
        controller.shutdown()
    }
}
