import MontazhkaCore
import Testing

@Suite
struct ProjectEditingTests {
    @Test
    func testCommandsChangeDocumentAndUndoRestoresWholeSnapshot() {
        var editor = ProjectEditor(project: Project(name: "Черновик"))
        var music = MusicSettings()
        music.enabled = true
        music.volume = 35

        editor.apply(.updateMusic(music))
        editor.apply(.rename("Готово"))
        #expect((editor.project.name) == ("Готово"))
        #expect((editor.project.music.volume) == (35))

        #expect((editor.undo()?.name) == ("Черновик"))
        #expect((editor.project.music) == (music))
        #expect((editor.undo()?.music) == (MusicSettings()))
    }
}
