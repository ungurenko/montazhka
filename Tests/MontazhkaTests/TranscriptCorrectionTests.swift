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

        let transcript = await service.transcript(
            AgentTranscriptRequest(target: AgentMediaTarget(projectID: project.id)))
        guard case .string(let text)? = transcript.data?["text"] else {
            Issue.record("нет текста расшифровки: \(String(describing: transcript.data))")
            return
        }
        #expect(text.contains("#3 1.60 2.10 вайбкодинг"))
        let glossaryURL = await service.store.glossaryURL
        #expect(Glossary.load(from: glossaryURL).entries.contains { $0.replace == "вайбкодинг" })
    }
}

/// `fixWords` меняет общие файлы (исправления расшифровки и словарь), а не ленту:
/// идёт отдельным вызовом, не прячет частично сохранённое и не теряет чужие правки.
extension TranscriptCorrectionTests {
    private struct Fixture {
        let root: URL
        let service: AgentService
        let project: Project
        let media: MediaReference
    }

    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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
        return Fixture(root: root, service: service, project: project, media: media)
    }

    private func fix(_ fixture: Fixture, words: AgentWordRange, text: String, remember: Bool) -> AgentEditOperation {
        var fix = AgentEditOperation(op: "fixWords")
        fix.words = [words]
        fix.text = text
        fix.remember = remember
        fix.timeline = AgentWordCuts.fingerprint(fixture.project.clips)
        return fix
    }

    @Test("a repeated source range cannot erase its own correction")
    func repeatedRangeIsRefused() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var project = fixture.project
        project.clips = [
            Clip(source: fixture.media, start: 0, end: 0.6),
            Clip(source: fixture.media, start: 0, end: 0.6),
        ]
        try await fixture.service.store.save(project)
        var operation = fix(fixture, words: AgentWordRange(from: 1, to: 2), text: "X", remember: false)
        operation.timeline = AgentWordCuts.fingerprint(project.clips)
        let response = await fixture.service.applyEdits(projectID: project.id, operations: [operation])
        #expect(!response.ok)
        #expect(!FileManager.default.fileExists(atPath: await fixesURL(fixture).path))
    }

    @Test("a damaged cached transcript stays a read-only cache miss")
    func invalidCacheDoesNotTranscribe() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = await fixture.service.makeTranscriptStore()
        let url = await store.cacheURL(for: fixture.media)
        try Data("broken JSON".utf8).write(to: url)
        #expect(try await store.correctedCachedWords(for: [fixture.media], glossaryURL: url) == nil)
        #expect(try Data(contentsOf: url) == Data("broken JSON".utf8))
    }

    @Test("a competing transcription rechecks the cache after taking ownership")
    func cacheIsRecheckedAfterLock() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = await fixture.service.makeTranscriptStore()
        let second = await fixture.service.makeTranscriptStore()
        let url = await first.cacheURL(for: fixture.media)
        let data = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        var ownership: FileLock? = try FileLock(guarding: url)
        let source = fixture.media
        let waiting = Task { try await first.ensure(source: source) }
        let competing = Task { try await second.ensure(source: source) }
        // Publish a ready document while both stores are waiting on the same owner.
        try await Task.sleep(for: .milliseconds(150))
        try data.write(to: url, options: .atomic)
        withExtendedLifetime(ownership) {}
        ownership = nil
        #expect(try await waiting.value.map(\.text) == ["вот", "мой", "вайб", "кодинг"])
        #expect(try await competing.value.map(\.text) == ["вот", "мой", "вайб", "кодинг"])
    }

    private func fixesURL(_ fixture: Fixture) async -> URL {
        TranscriptCorrections.url(
            forTranscript: await fixture.service.makeTranscriptStore().cacheURL(for: fixture.media))
    }

    @Test("fixWords mixed with other operations is refused before anything is written")
    func mixedBatchWritesNothing() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var layout = AgentEditOperation(op: "setLayout")
        layout.layout = "diagonal"

        let response = await fixture.service.applyEdits(
            projectID: fixture.project.id,
            operations: [
                fix(fixture, words: AgentWordRange(from: 3, to: 4), text: "вайбкодинг", remember: true), layout,
            ])

        #expect(!response.ok)
        #expect(response.error?.message.contains("fixWords") == true)
        #expect(!FileManager.default.fileExists(atPath: await fixesURL(fixture).path), "исправления не записаны")
        let glossaryURL = await fixture.service.store.glossaryURL
        #expect(!FileManager.default.fileExists(atPath: glossaryURL.path), "словарь не тронут")
    }

    @Test("a dictionary that cannot be written does not hide the fix that was saved")
    func glossaryFailureKeepsFixReported() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // На месте словаря — папка: записать его не выйдет.
        let glossaryURL = await fixture.service.store.glossaryURL
        try FileManager.default.createDirectory(at: glossaryURL, withIntermediateDirectories: true)

        let response = await fixture.service.applyEdits(
            projectID: fixture.project.id,
            operations: [fix(fixture, words: AgentWordRange(from: 3, to: 4), text: "вайбкодинг", remember: true)])

        #expect(response.ok, "исправление сохранено — команда не провалена: \(String(describing: response.error))")
        guard case .array(let warnings)? = response.data?["warnings"] else {
            Issue.record("нет предупреждений: \(String(describing: response.data))")
            return
        }
        #expect(warnings.contains { if case .string(let text) = $0 { text.contains("словар") } else { false } })
        #expect(TranscriptCorrections.load(from: await fixesURL(fixture))[2] == "вайбкодинг")
    }

    @Test("fixWords waits for the shared lock on the fixes file instead of writing over another writer")
    func fixesWaitForTheSharedLock() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let fixes = await fixesURL(fixture)
        var held: FileLock? = try FileLock(guarding: fixes)
        let operation = fix(fixture, words: AgentWordRange(from: 1, to: 1), text: "Вот", remember: false)
        let service = fixture.service
        let projectID = fixture.project.id

        let pending = Task { await service.applyEdits(projectID: projectID, operations: [operation]) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(!FileManager.default.fileExists(atPath: fixes.path), "пока другой пишет, fixWords ждёт")
        // Другой писатель успел сохранить своё исправление.
        try TranscriptCorrections.save([1: "мой-мой"], to: fixes)
        held = nil
        let response = await pending.value

        #expect(response.ok, "\(String(describing: response.error))")
        #expect(TranscriptCorrections.load(from: fixes) == [0: "Вот", 1: "мой-мой"], "обе правки на месте")
        withExtendedLifetime(held) {}
    }
}
