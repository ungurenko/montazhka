import Foundation

public struct TimelineSelection: Equatable {
    public static let minimumDuration = 0.05
    public let start: Double
    public let end: Double
    public var duration: Double { end - start }

    public init?(start: Double, end: Double, duration timelineDuration: Double) {
        guard timelineDuration > 0 else { return nil }
        let lower = min(max(0, min(start, end)), timelineDuration)
        let upper = min(max(0, max(start, end)), timelineDuration)
        guard upper - lower >= Self.minimumDuration else { return nil }
        self.start = lower
        self.end = upper
    }
}

public enum TimelineTrimEdge: Equatable, Sendable {
    case start
    case end
}

public enum TimelineOps {
    public static func shorteningClip(
        clips: [Clip],
        id: UUID,
        edge: TimelineTrimEdge,
        sourceTime: Double,
        minimumDuration: Double = 0.1
    ) -> [Clip] {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return clips }
        var clip = clips[index]
        switch edge {
        case .start:
            guard sourceTime > clip.start,
                sourceTime <= clip.end - minimumDuration
            else { return clips }
            clip.start = sourceTime
        case .end:
            guard sourceTime < clip.end,
                sourceTime >= clip.start + minimumDuration
            else { return clips }
            clip.end = sourceTime
        }
        var result = clips
        result[index] = clip
        return result
    }

    public static func removingRange(clips: [Clip], start: Double, end: Double) -> [Clip] {
        var result: [Clip] = []
        var acc = 0.0
        for clip in clips {
            let clipStart = acc
            let clipEnd = acc + clip.duration
            acc = clipEnd
            let cutFrom = max(start, clipStart)
            let cutTo = min(end, clipEnd)
            guard cutFrom < cutTo else { result.append(clip); continue }
            let sourceCutFrom = clip.start + (cutFrom - clipStart)
            let sourceCutTo = clip.start + (cutTo - clipStart)
            if sourceCutFrom > clip.start + 0.02 {
                var left = clip
                left.id = UUID()
                left.end = sourceCutFrom
                result.append(left)
            }
            if sourceCutTo < clip.end - 0.02 {
                var right = clip
                right.id = UUID()
                right.start = sourceCutTo
                result.append(right)
            }
        }
        return result
    }

    public static func splitting(clips: [Clip], at index: Int, offset: Double) -> [Clip]? {
        guard clips.indices.contains(index) else { return nil }
        let clip = clips[index]
        guard offset > 0.05, offset < clip.duration - 0.05 else { return nil }
        var left = clip
        left.end = clip.start + offset
        var right = clip
        right.id = UUID()
        right.start = clip.start + offset
        var result = clips
        result[index] = left
        result.insert(right, at: index + 1)
        return result
    }
}

public struct EditHistory<State> {
    private var undoStack: [State] = []
    private var redoStack: [State] = []
    private let limit: Int

    public init(limit: Int = 200) { self.limit = limit }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public mutating func record(_ state: State) {
        undoStack.append(state)
        if undoStack.count > limit { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    public mutating func undo(current: State) -> State? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return previous
    }

    public mutating func redo(current: State) -> State? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        return next
    }
}
