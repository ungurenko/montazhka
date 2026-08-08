import Foundation

struct TranscriptToken: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    let sourceID: UUID
    let text: String
    let start: Double
    let duration: Double
    let confidence: Float

    var end: Double { start + duration }
}

struct FillerCandidate: Identifiable, Equatable, Sendable {
    var id = UUID()
    let text: String
    let start: Double
    let end: Double
    var enabled = true
}

enum FillerDetector {
    private static let singleWords: Set<String> = ["э", "эм", "ну", "типа"]
    private static let padding = 0.08

    static func findCandidates(clips: [Clip], tokens: [TranscriptToken]) -> [FillerCandidate] {
        let grouped = Dictionary(grouping: tokens, by: \.sourceID)
        var timelineCursor = 0.0
        var candidates: [FillerCandidate] = []

        for clip in clips {
            let sourceTokens = (grouped[clip.source.id] ?? [])
                .filter { $0.start >= clip.start && $0.end <= clip.end }
                .sorted { $0.start < $1.start }
            var index = 0
            while index < sourceTokens.count {
                let token = sourceTokens[index]
                let normalized = normalize(token.text)
                if normalized == "как", index + 1 < sourceTokens.count {
                    let next = sourceTokens[index + 1]
                    if normalize(next.text) == "бы", next.start - token.end <= 0.4 {
                        candidates.append(candidate(text: "как бы", sourceStart: token.start,
                                                    sourceEnd: next.end, clip: clip,
                                                    timelineCursor: timelineCursor))
                        index += 2
                        continue
                    }
                }
                if singleWords.contains(normalized) {
                    candidates.append(candidate(text: token.text, sourceStart: token.start,
                                                sourceEnd: token.end, clip: clip,
                                                timelineCursor: timelineCursor))
                }
                index += 1
            }
            timelineCursor += clip.duration
        }
        return candidates.sorted { $0.start < $1.start }
    }

    private static func candidate(text: String, sourceStart: Double, sourceEnd: Double,
                                  clip: Clip, timelineCursor: Double) -> FillerCandidate {
        let start = max(timelineCursor, timelineCursor + sourceStart - clip.start - padding)
        let end = min(timelineCursor + clip.duration,
                      timelineCursor + sourceEnd - clip.start + padding)
        return FillerCandidate(text: text, start: start, end: end)
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased()
            .trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
    }
}
