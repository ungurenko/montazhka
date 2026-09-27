import Foundation
import Testing

@testable import MontazhkaKit

/// `montazhka_transcript` с `phrases` и `retakes` на проекте с расшифровкой в кэше.
@Suite("Agent transcript phrases and retake hints")
struct AgentRetakeTranscriptTests {
    private struct Fixture {
        let root: URL
        let service: AgentService
        let project: Project
    }

    /// 12 секунд: фраза «сегодня мы поговорим о монтаже» дважды (0,5–2,9 и 4,0–6,4),
    /// затем другая фраза (7,5–10,4). Звук громкий только под словами.
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-retakes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let video = root.appendingPathComponent("talk.mov")
        try await TestVideoFactory.make(
            segments: [
                (duration: 0.5, loud: false), (duration: 2.4, loud: true), (duration: 1.1, loud: false),
                (duration: 2.4, loud: true), (duration: 1.1, loud: false), (duration: 2.9, loud: true),
                (duration: 1.6, loud: false),
            ], to: video)
        let service = AgentService(baseDirectory: root)
        let media = MediaReference(url: video)
        let project = Project(name: "Дубли", clips: [Clip(source: media, start: 0, end: 12)])
        try await service.store.save(project)

        let sentence = ["сегодня", "мы", "поговорим", "о", "монтаже"]
        let other = ["это", "очень", "важная", "тема", "для", "всех"]
        let phrases: [(start: Double, texts: [String])] = [(0.5, sentence), (4.0, sentence), (7.5, other)]
        let words = phrases.flatMap { phrase in
            phrase.texts.enumerated().map { index, text in
                let start = phrase.start + Double(index) * 0.5
                return TranscriptWord(sourceID: media.id, text: text, start: start, end: start + 0.4, confidence: 1)
            }
        }
        let cacheURL = await service.makeTranscriptStore().cacheURL(for: media)
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(TranscriptDocument(words: words)).write(to: cacheURL)
        return Fixture(root: root, service: service, project: project)
    }

    private func request(
        _ fixture: Fixture, from: Double? = nil, to: Double? = nil, phrases: Bool = false, retakes: Bool = false
    ) -> AgentTranscriptRequest {
        AgentTranscriptRequest(
            target: AgentMediaTarget(projectID: fixture.project.id), from: from, to: to,
            phrases: phrases, retakes: retakes)
    }

    private func number(_ value: AgentJSONValue?) -> Int? {
        if case .number(let number)? = value { Int(number) } else { nil }
    }

    @Test("retakes over the whole timeline give word numbers that deleteWords accepts")
    func retakesFeedDeleteWords() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        // Страница — только первая фраза, но дубли ищутся по всей ленте.
        let response = await fixture.service.transcript(request(fixture, to: 3, retakes: true))

        #expect(response.ok, "\(String(describing: response.error))")
        #expect(number(response.data?["wordCount"]) == 5)
        guard case .array(let groups)? = response.data?["retakes"], groups.count == 1,
            case .object(let group)? = groups.first, case .array(let takes)? = group["takes"], takes.count == 2,
            case .object(let first)? = takes.first, case .object(let second)? = takes.last,
            case .string(let timeline)? = response.data?["timeline"]
        else {
            Issue.record("нет группы дублей: \(String(describing: response.data))")
            return
        }
        #expect(group["kind"] == .string("repeat"))
        #expect(group["similarity"] == .number(1))
        #expect(first["phrase"] == .number(1) && second["phrase"] == .number(2))
        #expect(first["from"] == .number(1) && first["to"] == .number(5))
        #expect(second["from"] == .number(6) && second["to"] == .number(10))
        #expect(second["start"] == .number(4) && second["end"] == .number(6.4))
        #expect(second["text"] == .string("сегодня мы поговорим о монтаже"))

        var cut = AgentEditOperation(op: "deleteWords")
        cut.words = [AgentWordRange(from: try #require(number(first["from"])), to: try #require(number(first["to"])))]
        cut.timeline = timeline
        let edited = await fixture.service.applyEdits(projectID: fixture.project.id, operations: [cut])
        #expect(edited.ok, "\(String(describing: edited.error))")

        let after = await fixture.service.transcript(request(fixture, retakes: true))
        #expect(number(after.data?["wordCount"]) == 11)
        #expect(after.data?["retakes"] == .array([]))
        guard case .string(let text)? = after.data?["text"] else {
            Issue.record("нет текста: \(String(describing: after.data))")
            return
        }
        #expect(text.split(separator: "\n").first?.hasSuffix(" сегодня") == true)
        #expect(!text.contains("#12 "))
    }

    @Test("phrases replace word lines with one numbered line per phrase")
    func phraseLines() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let response = await fixture.service.transcript(request(fixture, phrases: true))

        #expect(response.ok, "\(String(describing: response.error))")
        #expect(response.data?["timeline"] == .string(AgentWordCuts.fingerprint(fixture.project.clips)))
        #expect(number(response.data?["wordCount"]) == 16)
        #expect(response.data?["nextFrom"] == .null)
        #expect(
            response.data?["text"]
                == .string(
                    [
                        "¶1 #1–#5 0.50 2.90 сегодня мы поговорим о монтаже",
                        "¶2 #6–#10 4.00 6.40 сегодня мы поговорим о монтаже",
                        "¶3 #11–#16 7.50 10.40 это очень важная тема для всех",
                    ].joined(separator: "\n")))

        // Фраза, задетая диапазоном, показывается целиком.
        let tail = await fixture.service.transcript(request(fixture, from: 6, phrases: true))
        guard case .string(let text)? = tail.data?["text"] else {
            Issue.record("нет текста: \(String(describing: tail.data))")
            return
        }
        #expect(text.split(separator: "\n").map { String($0.prefix(2)) } == ["¶2", "¶3"])
    }
}
