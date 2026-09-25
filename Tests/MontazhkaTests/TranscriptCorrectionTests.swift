import Foundation
import Testing

@testable import MontazhkaKit

@Suite("Glossary and word fixes")
struct TranscriptCorrectionTests {
    private let source = UUID()

    private func words(_ texts: [String]) -> [TranscriptWord] {
        texts.enumerated().map { index, text in
            TranscriptWord(
                sourceID: source, text: text, start: Double(index), end: Double(index) + 0.5, confidence: 1)
        }
    }

    @Test("a two-word term becomes one term and keeps the numbering")
    func multiWordTerm() {
        let fixed = Glossary(entries: Glossary.starter).apply(to: words(["я", "открываю", "клод", "код,", "потом"]))
        #expect(fixed.map(\.text) == ["я", "открываю", "Claude Code,", "", "потом"])
        #expect(fixed.count == 5)
    }

    @Test("case endings and ё do not stop the match")
    func inflectionAndCase() {
        let glossary = Glossary(entries: Glossary.starter)
        #expect(glossary.apply(to: words(["у", "клода"])).map(\.text) == ["у", "Claude"])
        #expect(glossary.apply(to: words(["Чат", "ГПТ."])).map(\.text) == ["ChatGPT.", ""])
    }

    @Test("a hyphenated tail survives the replacement")
    func hyphenTail() {
        let glossary = Glossary(entries: Glossary.starter)
        #expect(glossary.apply(to: words(["вышел", "ГПТ-6,"])).map(\.text) == ["вышел", "GPT-6,"])
        #expect(glossary.apply(to: words(["в", "чат-жпти"])).map(\.text) == ["в", "ChatGPT"])
        #expect(glossary.apply(to: words(["клод-код"])).map(\.text) == ["Claude Code"])
        #expect(glossary.apply(to: words(["Клода", "опуса"])).map(\.text) == ["Claude", "Opus"])
    }

    @Test("ordinary words are left alone")
    func noFalseMatches() {
        let original = ["наведите", "курсор", "на", "кнопку"]
        #expect(Glossary(entries: Glossary.starter).apply(to: words(original)).map(\.text) == original)
    }

    @Test("a remembered fix is used next time")
    func rememberedEntry() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var glossary = Glossary.load(from: url)
        glossary.remember(original: ["вайб", "кодинг"], replacement: "вайбкодинг")
        try glossary.save(to: url)
        let reloaded = Glossary.load(from: url)
        #expect(reloaded.apply(to: words(["про", "вайб", "кодинг"])).map(\.text) == ["про", "вайбкодинг", ""])
        #expect(reloaded.entries.count == Glossary.starter.count + 1)
    }

    @Test("manual fixes replace a word range by position")
    func manualFixes() {
        let fixed = TranscriptCorrections.apply([1: "Codex", 2: ""], to: words(["в", "кодекс", "е", "дальше"]))
        #expect(fixed.map(\.text) == ["в", "Codex", "", "дальше"])
    }

    @Test("the agent fixes words by number and the transcript shows it")
    func agentFixWords() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("talk.mov")
        try await TestVideoFactory.make(segments: [(duration: 4, loud: true)], to: video)
        let service = AgentService(baseDirectory: root)
        let media = MediaReference(url: video)
        let project = Project(name: "Термины", clips: [Clip(source: media, start: 0, end: 4)])
        try await service.store.save(project)
        let spoken = ["вот", "мой", "вайб", "кодинг"].enumerated().map { index, text in
            TranscriptWord(
                sourceID: media.id, text: text, start: Double(index) * 0.8, end: Double(index) * 0.8 + 0.5,
                confidence: 1)
        }
        let cacheURL = await service.makeTranscriptStore().cacheURL(for: media)
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(TranscriptDocument(words: spoken)).write(to: cacheURL)

        var fix = AgentEditOperation(op: "fixWords")
        fix.words = [AgentWordRange(from: 3, to: 4)]
        fix.text = "вайбкодинг"
        fix.remember = true
        fix.timeline = AgentWordCuts.fingerprint(project.clips)
        let response = await service.applyEdits(projectID: project.id, operations: [fix])
        #expect(response.ok, "\(String(describing: response.error))")

        let transcript = await service.transcript(projectID: project.id, from: nil, to: nil)
        guard case .string(let text)? = transcript.data?["text"] else {
            Issue.record("нет текста расшифровки: \(String(describing: transcript.data))")
            return
        }
        #expect(text.contains("#3 1.60 2.10 вайбкодинг"))
        let glossaryURL = await service.store.glossaryURL
        #expect(Glossary.load(from: glossaryURL).entries.contains { $0.replace == "вайбкодинг" })
    }
}
