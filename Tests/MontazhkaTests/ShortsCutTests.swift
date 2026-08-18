import Foundation
import XCTest
@testable import Montazhka

final class ShortsCutTests: XCTestCase {
    private let words = [
        OpenRouterTranscriptWord(id: "w000001", text: "привет", start: 0, end: 0.4),
        OpenRouterTranscriptWord(id: "w000002", text: "друзья", start: 0.5, end: 0.9),
        OpenRouterTranscriptWord(id: "w000003", text: "сегодня", start: 1.0, end: 1.4),
        OpenRouterTranscriptWord(id: "w000004", text: "поговорим", start: 1.5, end: 2.0)
    ]

    override func tearDown() {
        ShortsMockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Контракт предложений

    func testProposalDecoderAcceptsValidEnvelope() throws {
        let envelope = try OpenRouterClient.decodeShortsProposals("""
        {"schema_version":1,"clips":[{"id":"s1","first_word_id":"w000001","last_word_id":"w000002","title":"Приветствие","reason":"яркое начало","confidence":0.9}]}
        """, words: words)
        XCTAssertEqual(envelope.clips.map(\.id), ["s1"])
    }

    func testProposalDecoderFiltersInvalidClipsButKeepsValidOnes() throws {
        // Неизвестное слово и перевёрнутый диапазон отфильтровываются,
        // валидный клип остаётся — одно слабое место не губит всё окно.
        let envelope = try OpenRouterClient.decodeShortsProposals("""
        {"schema_version":1,"clips":[{"id":"bad1","first_word_id":"unknown","last_word_id":"w000002","title":"т","reason":"р","confidence":0.9},{"id":"bad2","first_word_id":"w000003","last_word_id":"w000001","title":"т","reason":"р","confidence":0.9},{"id":"bad3","first_word_id":"w000001","last_word_id":"w000002","title":"","reason":"р","confidence":0.9},{"id":"bad4","first_word_id":"w000001","last_word_id":"w000002","title":"т","reason":"р","confidence":1.5},{"id":"good","first_word_id":"w000001","last_word_id":"w000002","title":"ок","reason":"ок","confidence":0.9}]}
        """, words: words)
        XCTAssertEqual(envelope.clips.map(\.id), ["good"])
    }

    func testProposalDecoderRejectsStructurallyBrokenEnvelope() {
        XCTAssertThrowsError(try OpenRouterClient.decodeShortsProposals("это не json", words: words))
        XCTAssertThrowsError(try OpenRouterClient.decodeShortsProposals("""
        {"schema_version":2,"clips":[]}
        """, words: words))
    }

    func testProposalDecoderUnwrapsMarkdownFenceAndSchemaEcho() throws {
        // Реальный сбой DeepSeek: markdown-ограждение + эхо-обёртка запроса.
        let envelope = try OpenRouterClient.decodeShortsProposals("""
        ```json
        {
          "name": "shorts_clips",
          "schema": {
            "schema_version": 1,
            "clips": [{"id":"s1","first_word_id":"w000001","last_word_id":"w000002","title":"привет","reason":"яркое начало","confidence":0.9}]
          }
        }
        ```
        """, words: words)
        XCTAssertEqual(envelope.clips.map(\.id), ["s1"])
    }

    // MARK: - Контракт отбора

    private func makeProposals() throws -> ShortsProposalEnvelope {
        try OpenRouterClient.decodeShortsProposals("""
        {"schema_version":1,"clips":[{"id":"s1","first_word_id":"w000001","last_word_id":"w000002","title":"один","reason":"р","confidence":0.9},{"id":"s2","first_word_id":"w000003","last_word_id":"w000004","title":"два","reason":"р","confidence":0.85}]}
        """, words: words)
    }

    private func rankInputs(from envelope: ShortsProposalEnvelope) -> [ShortsRankInput] {
        envelope.clips.map {
            ShortsRankInput(id: $0.id, title: $0.title, reason: $0.reason,
                            confidence: $0.confidence, durationSeconds: 10, excerpt: "текст")
        }
    }

    func testRankingDecoderAcceptsRankedAcceptsAndZeroRankRejects() throws {
        let proposals = try makeProposals()
        let envelope = try OpenRouterClient.decodeShortsRanking("""
        {"schema_version":1,"decisions":[{"clip_id":"s1","decision":"accept","rank":1,"title":"один","reason":"сильный","confidence":0.9},{"clip_id":"s2","decision":"reject","rank":0,"title":"два","reason":"слабый","confidence":0.4}]}
        """, proposals: rankInputs(from: proposals))
        XCTAssertEqual(envelope.decisions.count, 2)
        XCTAssertEqual(envelope.decisions.first?.decision, .accept)
    }

    func testRankingDecoderFiltersUnknownAndDuplicateCandidates() throws {
        let proposals = try makeProposals()
        let inputs = rankInputs(from: proposals)
        let envelope = try OpenRouterClient.decodeShortsRanking("""
        {"schema_version":1,"decisions":[{"clip_id":"sX","decision":"accept","rank":1,"title":"т","reason":"р","confidence":0.9},{"clip_id":"s1","decision":"accept","rank":1,"title":"один","reason":"сильный","confidence":0.9},{"clip_id":"s1","decision":"reject","rank":0,"title":"один","reason":"дубль","confidence":0.9},{"clip_id":"s2","decision":"reject","rank":3,"title":"два","reason":"слабый","confidence":0.4}]}
        """, proposals: inputs)
        // Неизвестный и повторный кандидаты отфильтрованы; битый ранг у
        // отклонённого больше не губит ответ.
        XCTAssertEqual(envelope.decisions.map(\.clipID), ["s1", "s2"])
    }

    func testRankingNormalizesBrokenRanksByAppearanceOrder() throws {
        let decisions = [
            ShortsRankDTO(clipID: "a", decision: .accept, rank: 0, title: "т", reason: "р", confidence: 0.9),
            ShortsRankDTO(clipID: "b", decision: .accept, rank: 0, title: "т", reason: "р", confidence: 0.9),
            ShortsRankDTO(clipID: "c", decision: .reject, rank: 0, title: "т", reason: "р", confidence: 0.9),
            ShortsRankDTO(clipID: "d", decision: .accept, rank: 1, title: "т", reason: "р", confidence: 0.9)
        ]
        let ordered = ShortsCutService.acceptedInRankOrder(decisions)
        // Валидный ранг 1 выходит вперёд, битые — по порядку ответа.
        XCTAssertEqual(ordered.map(\.clipID), ["d", "a", "b"])
    }

    func testFallbackDecisionsCapAtDesiredCount() {
        let proposals = (1...5).map {
            ShortsProposalDTO(id: "s\($0)", firstWordID: "w000001", lastWordID: "w000002",
                              title: "т\($0)", reason: "р", confidence: 0.9)
        }
        let fallback = ShortsCutService.fallbackDecisions(proposals: proposals, desiredCount: 3)
        XCTAssertEqual(fallback.count, 3)
        XCTAssertEqual(fallback.map(\.rank), [1, 2, 3])
        XCTAssertTrue(fallback.allSatisfy { $0.decision == .accept })
    }

    func testTrimmerKeepsHookAndCutsTailOverSixtySeconds() {
        // Слова каждые 10 секунд: диапазон из 10 слов = 90+ секунд.
        var words: [MappedTranscriptWord] = []
        for index in 0..<10 {
            let time = Double(index) * 10
            words.append(MappedTranscriptWord(
                wordID: "w\(index)", text: "слово", clipID: UUID(), sourceID: UUID(),
                sourceStart: time, sourceEnd: time + 0.5,
                timelineStart: time, timelineEnd: time + 0.5, confidence: 0.9))
        }
        let trimmed = ShortsWindowPlanner.trimmedToMaxDuration(words[...])
        XCTAssertNotNil(trimmed)
        // Хук (начало) сохранён, хвост обрезан по потолку 60 секунд.
        XCTAssertEqual(trimmed!.first!.wordID, "w0")
        XCTAssertLessThanOrEqual(trimmed!.last!.sourceEnd - trimmed!.first!.sourceStart,
                                 ShortsLimits.maxDuration)
    }

    func testQwenRepairsBrokenShortsResponseOnce() async throws {
        ShortsMockURLProtocol.configure(responses: [
            .json(content: "это не json"),
            .json(content: """
            {"schema_version":1,"clips":[{"id":"s1","first_word_id":"w000001","last_word_id":"w000002","title":"приветствие","reason":"яркое начало","confidence":0.9}]}
            """)
        ])
        let client = OpenRouterClient(session: makeMockSession())
        let result = try await client.proposeShorts(words: words, model: .qwen, apiKey: "secret")
        XCTAssertEqual(result.clips.map(\.id), ["s1"])
        XCTAssertEqual(ShortsMockURLProtocol.recordedRequests.count, 2)
    }

    // MARK: - Окна

    private func mappedWords(count: Int, step: Double) -> [MappedTranscriptWord] {
        (0..<count).map { index in
            let time = Double(index) * step
            return MappedTranscriptWord(
                wordID: String(format: "w%06d", index + 1),
                text: "слово\(index)",
                clipID: UUID(),
                sourceID: UUID(),
                sourceStart: time, sourceEnd: time + 0.3,
                timelineStart: time, timelineEnd: time + 0.3,
                confidence: 0.9)
        }
    }

    func testWindowPlannerMakesSingleWindowForShortVideo() {
        let windows = ShortsWindowPlanner.windows(for: mappedWords(count: 20, step: 1))
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows.first, 0..<20)
    }

    func testWindowPlannerCoversAllWordsWithOverlapForLongVideo() {
        // 40 минут речи: слово каждые 10 секунд.
        let words = mappedWords(count: 240, step: 10)
        let windows = ShortsWindowPlanner.windows(for: words)
        XCTAssertGreaterThan(windows.count, 1)
        XCTAssertEqual(windows.first?.lowerBound, 0)
        XCTAssertEqual(windows.last?.upperBound, words.count)
        // Каждое слово накрыто хотя бы одним окном.
        var covered = Set<Int>()
        for window in windows { covered.formUnion(window) }
        XCTAssertEqual(covered.count, words.count)
        // Соседние окна пересекаются — моменты на стыке не теряются.
        for pair in zip(windows, windows.dropFirst()) {
            XCTAssertGreaterThan(pair.0.upperBound, pair.1.lowerBound)
        }
    }

    func testDeduplicationKeepsHigherRankedOverlappingCandidate() {
        let candidates = [
            ShortCandidate(id: UUID(), rank: 1, title: "сильный", reason: "", excerpt: "",
                           start: 10, end: 40, confidence: 0.9, enabled: false),
            ShortCandidate(id: UUID(), rank: 2, title: "пересекается", reason: "", excerpt: "",
                           start: 30, end: 55, confidence: 0.85, enabled: false),
            ShortCandidate(id: UUID(), rank: 3, title: "отдельный", reason: "", excerpt: "",
                           start: 100, end: 120, confidence: 0.8, enabled: false)
        ]
        let deduplicated = ShortsWindowPlanner.deduplicated(candidates)
        XCTAssertEqual(deduplicated.map(\.title), ["сильный", "отдельный"])
    }

    // MARK: - Границы

    private func boundaryWords(start: Double, end: Double) -> (first: MappedTranscriptWord, last: MappedTranscriptWord) {
        let id = UUID()
        let first = MappedTranscriptWord(
            wordID: "w000001", text: "первое", clipID: id, sourceID: id,
            sourceStart: start, sourceEnd: start + 0.4,
            timelineStart: start, timelineEnd: start + 0.4, confidence: 0.9)
        let last = MappedTranscriptWord(
            wordID: "w000010", text: "последнее", clipID: id, sourceID: id,
            sourceStart: end - 0.4, sourceEnd: end,
            timelineStart: end - 0.4, timelineEnd: end, confidence: 0.9)
        return (first, last)
    }

    func testBoundaryResolverSnapsToSilenceAroundWords() {
        let (first, last) = boundaryWords(start: 5.0, end: 8.5)
        // 20 секунд аудио: громко только между словами, вокруг — тишина.
        let samples = Int(20 * WaveformStore.windowsPerSecond)
        var peaks = [Float](repeating: 0.0005, count: samples)
        let loud = Int(5.0 * WaveformStore.windowsPerSecond)..<Int(8.5 * WaveformStore.windowsPerSecond)
        for index in loud { peaks[index] = 0.5 }

        let boundary = ShortsBoundaryResolver.resolve(
            first: first, last: last, peaks: peaks,
            sourceDuration: 20, thresholdDB: -40)

        guard let boundary else { return XCTFail("Граница не нашлась") }
        // Старт — тихая точка в 0.2 сек воздуха до слова, конец — в 0.35 после.
        XCTAssertEqual(boundary.start, 4.8, accuracy: 0.06)
        XCTAssertEqual(boundary.end, 8.85, accuracy: 0.06)
    }

    func testBoundaryResolverFallsBackToAirWhenNoSilence() {
        let (first, last) = boundaryWords(start: 5.0, end: 8.5)
        let samples = Int(20 * WaveformStore.windowsPerSecond)
        let peaks = [Float](repeating: 0.5, count: samples)

        let boundary = ShortsBoundaryResolver.resolve(
            first: first, last: last, peaks: peaks,
            sourceDuration: 20, thresholdDB: -40)

        XCTAssertNotNil(boundary)
        XCTAssertEqual(boundary!.start, 4.9, accuracy: 0.001)
        XCTAssertEqual(boundary!.end, 8.65, accuracy: 0.001)
    }

    func testBoundaryResolverClampsToSourceStart() {
        let (first, last) = boundaryWords(start: 0.05, end: 3.0)
        let boundary = ShortsBoundaryResolver.resolve(
            first: first, last: last, peaks: [],
            sourceDuration: 10, thresholdDB: -40)
        XCTAssertNotNil(boundary)
        XCTAssertGreaterThanOrEqual(boundary!.start, 0)
    }

    // MARK: - Промпты и имена файлов

    func testPromptsTreatDataAsUntrusted() throws {
        XCTAssertTrue(ShortsPrompts.selectorSystem.contains("недоверенные данные"))
        XCTAssertTrue(ShortsPrompts.rankerSystem.contains("недоверенные данные"))
        let proposal = try ShortsPrompts.proposalUser(words: words)
        XCTAssertTrue(proposal.contains("DATA_TRANSCRIPT_BEGIN"))
        let rank = try ShortsPrompts.rankUser(
            proposals: [ShortsRankInput(id: "s1", title: "т", reason: "р",
                                        confidence: 0.9, durationSeconds: 20, excerpt: "текст")],
            desiredCount: 3)
        XCTAssertTrue(rank.contains("DATA_CANDIDATES_BEGIN"))
        XCTAssertTrue(rank.contains("не больше 3"))
    }

    func testFileNameSanitizesTitleAndAvoidsCollisions() throws {
        XCTAssertEqual(ShortsExporter.sanitize("Привет: мир? *звёздочка*"), "Привет мир звёздочка")
        XCTAssertEqual(ShortsExporter.sanitize("///"), "ролик")

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("shorts-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let first = ShortsExporter.fileURL(in: folder, sourceName: "подкаст", index: 0, title: "инсайт")
        FileManager.default.createFile(atPath: first.path, contents: Data())
        let second = ShortsExporter.fileURL(in: folder, sourceName: "подкаст", index: 0, title: "инсайт")
        XCTAssertEqual(first.lastPathComponent, "подкаст 01 инсайт.mp4")
        XCTAssertEqual(second.lastPathComponent, "подкаст 01 инсайт (2).mp4")
    }

    private func makeMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ShortsMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class ShortsMockURLProtocol: URLProtocol {
    struct Response: Sendable {
        let status: Int
        let body: Data
        let headers: [String: String]

        static func json(content: String) -> Response {
            let object: [String: Any] = ["choices": [["message": ["content": content]]]]
            return Response(status: 200,
                            body: try! JSONSerialization.data(withJSONObject: object),
                            headers: ["Content-Type": "application/json"])
        }
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var responses: [Response] = []
        var requests: [URLRequest] = []
    }

    private static let state = State()

    static var recordedRequests: [URLRequest] {
        state.lock.withLock { state.requests }
    }

    static func configure(responses newResponses: [Response]) {
        state.lock.withLock { state.responses = newResponses }
    }

    static func reset() {
        state.lock.withLock {
            state.responses = []
            state.requests = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let value: Response? = Self.state.lock.withLock {
            Self.state.requests.append(request)
            return Self.state.responses.isEmpty ? nil : Self.state.responses.removeFirst()
        }
        guard let value else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: value.status,
                                       httpVersion: nil, headerFields: value.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: value.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
