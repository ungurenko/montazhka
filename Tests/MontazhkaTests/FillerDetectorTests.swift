import Foundation
import Testing

@testable import MontazhkaKit

@Suite("Sound without words")
struct FillerDetectorTests {
    /// Пики по 100 окон в секунду: громко внутри `loud`, тихо вокруг.
    private func peaks(seconds: Double, loud: [ClosedRange<Double>]) -> [Float] {
        (0..<Int(seconds * 100)).map { index in
            let time = Double(index) / 100
            return loud.contains { $0.contains(time) } ? 0.3 : 0.001
        }
    }

    @Test("a voiced gap between words is found")
    func findsHum() throws {
        let span = try #require(
            FillerDetector.voicedSpan(from: 0.8, to: 1.6, peaks: peaks(seconds: 3, loud: [1.0...1.4]), thresholdDB: -40))
        #expect(abs(span.lowerBound - 1.0) < 0.02)
        #expect(abs(span.upperBound - 1.4) < 0.03)
    }

    @Test("a quiet pause is not a filler")
    func silenceIsNotHum() {
        #expect(FillerDetector.voicedSpan(from: 0.8, to: 1.6, peaks: peaks(seconds: 3, loud: []), thresholdDB: -40) == nil)
    }

    @Test("a click shorter than a quarter second is ignored")
    func clickIgnored() {
        let short = peaks(seconds: 3, loud: [1.0...1.1])
        #expect(FillerDetector.voicedSpan(from: 0.8, to: 1.6, peaks: short, thresholdDB: -40) == nil)
    }

    @Test("only short hums count as fillers to cut")
    func fillerLength() {
        #expect(FillerDetector.isLikelyFiller(0.5...1.0))
        #expect(!FillerDetector.isLikelyFiller(0.0...2.5))
    }

    @Test("the agent transcript marks sound without words")
    func transcriptMarksHum() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("talk.mov")
        try await TestVideoFactory.make(segments: [(duration: 4, loud: true)], to: video)
        let service = AgentService(baseDirectory: root)
        let media = MediaReference(url: video)
        let project = Project(name: "Эээ", clips: [Clip(source: media, start: 0, end: 4)])
        try await service.store.save(project)
        let spoken = [
            TranscriptWord(sourceID: media.id, text: "итак", start: 0, end: 0.5, confidence: 1),
            TranscriptWord(sourceID: media.id, text: "начнём", start: 1.4, end: 2.0, confidence: 1),
        ]
        let cacheURL = await service.makeTranscriptStore().cacheURL(for: media)
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(TranscriptDocument(words: spoken)).write(to: cacheURL)

        let transcript = await service.transcript(projectID: project.id, from: nil, to: nil)
        guard case .string(let text)? = transcript.data?["text"] else {
            Issue.record("нет текста расшифровки")
            return
        }
        #expect(text.contains("--- звук без слов"), "\(text)")
    }
}
