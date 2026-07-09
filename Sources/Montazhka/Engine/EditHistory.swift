import Foundation

/// Стек отмены/повтора для снимков состояния; хранит не больше `limit` шагов.
struct EditHistory<State> {
    private var undoStack: [State] = []
    private var redoStack: [State] = []
    private let limit: Int

    init(limit: Int = 200) {
        self.limit = limit
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Записывает снимок перед правкой; ветка повтора сбрасывается.
    mutating func record(_ state: State) {
        undoStack.append(state)
        if undoStack.count > limit { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    /// Возвращает предыдущий снимок, запоминая текущее состояние для повтора.
    mutating func undo(current: State) -> State? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return previous
    }

    /// Возвращает отменённый снимок, запоминая текущее состояние для отмены.
    mutating func redo(current: State) -> State? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        return next
    }
}
