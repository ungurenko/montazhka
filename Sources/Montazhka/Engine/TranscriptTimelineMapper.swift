import Foundation

struct MappedTranscriptWord: Equatable, Sendable {
    let wordID: String
    let text: String
    let clipID: UUID
    let sourceID: UUID
    let sourceStart: Double
    let sourceEnd: Double
    let timelineStart: Double
    let timelineEnd: Double
    let confidence: Float

    var publicPayload: OpenRouterTranscriptWord {
        OpenRouterTranscriptWord(
            id: wordID, text: text,
            start: timelineStart, end: timelineEnd)
    }
}

struct OpenRouterTranscriptWord: Codable, Equatable, Sendable {
    let id: String
    let text: String
    let start: Double
    let end: Double
}

struct TranscriptTimelineMap: Sendable {
    let snapshot: SmartEditSnapshot
    let words: [MappedTranscriptWord]
    private let indices: [String: Int]

    init(snapshot: SmartEditSnapshot, words: [MappedTranscriptWord]) {
        self.snapshot = snapshot
        self.words = words
        indices = Dictionary(uniqueKeysWithValues: words.enumerated().map { ($0.element.wordID, $0.offset) })
    }

    func range(firstWordID: String, lastWordID: String) -> ArraySlice<MappedTranscriptWord>? {
        guard let first = indices[firstWordID], let last = indices[lastWordID], first <= last else { return nil }
        let slice = words[first...last]
        guard let clipID = slice.first?.clipID,
            slice.allSatisfy({ $0.clipID == clipID })
        else { return nil }
        return slice
    }
}

enum TranscriptTimelineMapper {
    static func make(clips: [Clip], transcripts: [TranscriptWord]) -> TranscriptTimelineMap {
        let snapshot = SmartEditSnapshot(clips: clips)
        let grouped = Dictionary(grouping: transcripts, by: \.sourceID)
        var timelineOffset = 0.0
        var mapped: [MappedTranscriptWord] = []

        for clip in clips {
            let visible = (grouped[clip.source.id] ?? [])
                .filter { $0.start >= clip.start - 0.005 && $0.end <= clip.end + 0.005 }
                .sorted { $0.start < $1.start }
            for word in visible {
                let number = mapped.count + 1
                mapped.append(
                    MappedTranscriptWord(
                        wordID: String(format: "w%06d", number),
                        text: word.text,
                        clipID: clip.id,
                        sourceID: clip.source.id,
                        sourceStart: word.start,
                        sourceEnd: word.end,
                        timelineStart: timelineOffset + word.start - clip.start,
                        timelineEnd: timelineOffset + word.end - clip.start,
                        confidence: word.confidence
                    ))
            }
            timelineOffset += clip.duration
        }
        return TranscriptTimelineMap(snapshot: snapshot, words: mapped)
    }
}
