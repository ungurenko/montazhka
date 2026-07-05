import Foundation

/// Чистая математика ленты — отдельно, чтобы её можно было проверять тестами.
enum TimelineOps {
    /// Вырезает кусок ленты [start, end]; лента смыкается сама.
    static func removingRange(clips: [Clip], start: Double, end: Double) -> [Clip] {
        var result: [Clip] = []
        var acc = 0.0
        for clip in clips {
            let clipStart = acc
            let clipEnd = acc + clip.duration
            acc = clipEnd

            let cutFrom = max(start, clipStart)
            let cutTo = min(end, clipEnd)
            guard cutFrom < cutTo else {
                result.append(clip)
                continue
            }
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

    /// Делит клип с позицией `offset` секунд от его начала на два.
    static func splitting(clips: [Clip], at index: Int, offset: Double) -> [Clip]? {
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
