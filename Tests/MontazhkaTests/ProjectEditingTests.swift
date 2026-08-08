import XCTest
import MontazhkaCore

final class ProjectEditingTests: XCTestCase {
    func testCommandsChangeDocumentAndUndoRestoresWholeSnapshot() {
        var editor = ProjectEditor(project: Project(name: "Черновик"))
        var music = MusicSettings()
        music.enabled = true
        music.volume = 35

        editor.apply(.updateMusic(music))
        editor.apply(.rename("Готово"))
        XCTAssertEqual(editor.project.name, "Готово")
        XCTAssertEqual(editor.project.music.volume, 35)

        XCTAssertEqual(editor.undo()?.name, "Черновик")
        XCTAssertEqual(editor.project.music, music)
        XCTAssertEqual(editor.undo()?.music, MusicSettings())
    }
}
