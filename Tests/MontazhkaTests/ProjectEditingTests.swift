import Testing

@testable import MontazhkaKit

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

    @Test
    func testEditHistoryClearsRedoBranchAndKeepsItsLimit() {
        var history = EditHistory<Int>(limit: 3)
        #expect(!history.canUndo && !history.canRedo)
        #expect(history.undo(current: 0) == nil)
        #expect(history.redo(current: 0) == nil)

        history.record(1)
        history.record(2)
        #expect(history.undo(current: 3) == 2)
        #expect(history.undo(current: 2) == 1)
        #expect(history.redo(current: 1) == 2)
        #expect(history.redo(current: 2) == 3)
        #expect(!history.canRedo)

        #expect(history.undo(current: 3) == 2)
        history.record(2)
        #expect(!history.canRedo)

        var capped = EditHistory<Int>(limit: 3)
        for value in 1...5 { capped.record(value) }
        #expect(capped.undo(current: 6) == 5)
        #expect(capped.undo(current: 5) == 4)
        #expect(capped.undo(current: 4) == 3)
        #expect(!capped.canUndo)
    }

    @Test
    func testBatchClipEditIsOneUndoableChange() {
        let clip = Clip(sourcePath: "/tmp/smart-edit.mov", start: 1, end: 9)
        var editor = ProjectEditor(project: Project(name: "Тест", clips: [clip]))
        editor.recordCurrent()
        editor.apply(
            .replaceClips(
                TimelineOps.removingRange(
                    clips: editor.project.clips,
                    start: 1,
                    end: 2)),
            recordHistory: false)

        #expect(editor.project.clips.count == 2)
        #expect(editor.undo()?.clips == [clip])
        #expect(editor.redo()?.clips.count == 2)
    }
}
