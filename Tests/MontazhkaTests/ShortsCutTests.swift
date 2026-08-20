import Foundation
import Testing

@testable import MontazhkaKit

@Suite(.serialized)
struct ShortsCutTests {
    private let words = [
        OpenRouterTranscriptWord(id: "w000001", text: "привет", start: 0, end: 0.4),
        OpenRouterTranscriptWord(id: "w000002", text: "друзья", start: 0.5, end: 0.9),
        OpenRouterTranscriptWord(id: "w000003", text: "сегодня", start: 1.0, end: 1.4),
        OpenRouterTranscriptWord(id: "w000004", text: "поговорим", start: 1.5, end: 2.0),
    ]

    init() {
        ShortsMockURLProtocol.reset()
    }

    // MARK: - Контракт предложений

    @Test
    func testProposalDecoderAcceptsValidEnvelope() throws {
        let envelope = try OpenRouterClient.decodeShortsProposals(
            """
            {"schema_version":1,"clips":[{"id":"s1","first_word_id":"w000001","last_word_id":"w000002","title":"Приветствие","reason":"яркое начало","confidence":0.9,"hook":"все думают что","pattern":"мнение","topic":"деньги","hook_score":8,"standalone_score":9,"payoff_score":7,"pacing_score":6}]}
            """, words: words)
        #expect((envelope.clips.map(\.id)) == (["s1"]))
        #expect((envelope.clips.first?.hook) == ("все думают что"))
        #expect((envelope.clips.first?.pattern) == ("мнение"))
        #expect((envelope.clips.first?.hookScore) == (8))
    }

    @Test
    func testProposalDecoderFillsDefaultsForMissingOptionalFields() throws {
        // qwen отвечает без строгой схемы: новые поля могут отсутствовать.
        let envelope = try OpenRouterClient.decodeShortsProposals(
            """
            {"schema_version":1,"clips":[{"id":"s1","first_word_id":"w000001","last_word_id":"w000002","title":"т","reason":"р","confidence":0.9}]}
            """, words: words)
        #expect((envelope.clips.first?.hook) == (""))
        #expect((envelope.clips.first?.pattern) == (""))
        #expect((envelope.clips.first?.hookScore) == (5))
        #expect((envelope.clips.first?.pacingScore) == (5))
    }

    @Test
    func testProposalDecoderClampsRunawayScores() throws {
        let envelope = try OpenRouterClient.decodeShortsProposals(
            """
            {"schema_version":1,"clips":[{"id":"s1","first_word_id":"w000001","last_word_id":"w000002","title":"т","reason":"р","confidence":0.9,"hook_score":42,"pacing_score":-3}]}
            """, words: words)
        #expect((envelope.clips.first?.hookScore) == (10))
        #expect((envelope.clips.first?.pacingScore) == (0))
    }

    @Test
    func testProposalDecoderFiltersInvalidClipsButKeepsValidOnes() throws {
        // Неизвестное слово и перевёрнутый диапазон отфильтровываются,
        // валидный клип остаётся — одно слабое место не губит всё окно.
        let envelope = try OpenRouterClient.decodeShortsProposals(
            """
            {"schema_version":1,"clips":[{"id":"bad1","first_word_id":"unknown","last_word_id":"w000002","title":"т","reason":"р","confidence":0.9},{"id":"bad2","first_word_id":"w000003","last_word_id":"w000001","title":"т","reason":"р","confidence":0.9},{"id":"bad3","first_word_id":"w000001","last_word_id":"w000002","title":"","reason":"р","confidence":0.9},{"id":"bad4","first_word_id":"w000001","last_word_id":"w000002","title":"т","reason":"р","confidence":1.5},{"id":"good","first_word_id":"w000001","last_word_id":"w000002","title":"ок","reason":"ок","confidence":0.9}]}
            """, words: words)
        #expect((envelope.clips.map(\.id)) == (["good"]))
    }

    @Test
    func testProposalDecoderRejectsStructurallyBrokenEnvelope() {
        #expect(throws: (any Error).self) {
            try OpenRouterClient.decodeShortsProposals("это не json", words: words)
        }
        #expect(throws: (any Error).self) {
            try OpenRouterClient.decodeShortsProposals(
                """
                {"schema_version":2,"clips":[]}
                """, words: words)
        }
    }

    @Test
    func testProposalDecoderUnwrapsMarkdownFenceAndSchemaEcho() throws {
        // Реальный сбой DeepSeek: markdown-ограждение + эхо-обёртка запроса.
        let envelope = try OpenRouterClient.decodeShortsProposals(
            """
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
        #expect((envelope.clips.map(\.id)) == (["s1"]))
    }

    // MARK: - Контракт отбора

    private func makeProposals() throws -> ShortsProposalEnvelope {
        try OpenRouterClient.decodeShortsProposals(
            """
            {"schema_version":1,"clips":[{"id":"s1","first_word_id":"w000001","last_word_id":"w000002","title":"один","reason":"р","confidence":0.9},{"id":"s2","first_word_id":"w000003","last_word_id":"w000004","title":"два","reason":"р","confidence":0.85}]}
            """, words: words)
    }

    private func rankInputs(from envelope: ShortsProposalEnvelope) -> [ShortsRankInput] {
        envelope.clips.map {
            ShortsRankInput(
                id: $0.id, title: $0.title, reason: $0.reason,
                confidence: $0.confidence, durationSeconds: 10, excerpt: "текст",
                hook: $0.hook, pattern: $0.pattern, topic: $0.topic,
                hookScore: $0.hookScore, standaloneScore: $0.standaloneScore,
                payoffScore: $0.payoffScore, pacingScore: $0.pacingScore)
        }
    }

    @Test
    func testRankingDecoderAcceptsRankedAcceptsAndZeroRankRejects() throws {
        let proposals = try makeProposals()
        let envelope = try OpenRouterClient.decodeShortsRanking(
            """
            {"schema_version":1,"decisions":[{"clip_id":"s1","decision":"accept","rank":1,"title":"один","reason":"сильный","confidence":0.9},{"clip_id":"s2","decision":"reject","rank":0,"title":"два","reason":"слабый","confidence":0.4}]}
            """, proposals: rankInputs(from: proposals))
        #expect((envelope.decisions.count) == (2))
        #expect((envelope.decisions.first?.decision) == (.accept))
    }

    @Test
    func testRankingDecoderFiltersUnknownAndDuplicateCandidates() throws {
        let proposals = try makeProposals()
        let inputs = rankInputs(from: proposals)
        let envelope = try OpenRouterClient.decodeShortsRanking(
            """
            {"schema_version":1,"decisions":[{"clip_id":"sX","decision":"accept","rank":1,"title":"т","reason":"р","confidence":0.9},{"clip_id":"s1","decision":"accept","rank":1,"title":"один","reason":"сильный","confidence":0.9},{"clip_id":"s1","decision":"reject","rank":0,"title":"один","reason":"дубль","confidence":0.9},{"clip_id":"s2","decision":"reject","rank":3,"title":"два","reason":"слабый","confidence":0.4}]}
            """, proposals: inputs)
        // Неизвестный и повторный кандидаты отфильтрованы; битый ранг у
        // отклонённого больше не губит ответ.
        #expect((envelope.decisions.map(\.clipID)) == (["s1", "s2"]))
    }

    @Test
    func testRankingNormalizesBrokenRanksByAppearanceOrder() throws {
        let decisions = [
            ShortsRankDTO(clipID: "a", decision: .accept, rank: 0, title: "т", reason: "р", confidence: 0.9),
            ShortsRankDTO(clipID: "b", decision: .accept, rank: 0, title: "т", reason: "р", confidence: 0.9),
            ShortsRankDTO(clipID: "c", decision: .reject, rank: 0, title: "т", reason: "р", confidence: 0.9),
            ShortsRankDTO(clipID: "d", decision: .accept, rank: 1, title: "т", reason: "р", confidence: 0.9),
        ]
        let ordered = ShortsCutService.acceptedInRankOrder(decisions)
        // Валидный ранг 1 выходит вперёд, битые — по порядку ответа.
        #expect((ordered.map(\.clipID)) == (["d", "a", "b"]))
    }

    @Test
    func testFallbackDecisionsCapAtDesiredCount() {
        let proposals = (1...5).map {
            ShortsProposalDTO(
                id: "s\($0)", firstWordID: "w000001", lastWordID: "w000002",
                title: "т\($0)", reason: "р", confidence: 0.9,
                hook: "", pattern: "", topic: "",
                hookScore: 5, standaloneScore: 5,
                payoffScore: 5, pacingScore: 5)
        }
        let fallback = ShortsCutService.fallbackDecisions(proposals: proposals, desiredCount: 3)
        #expect((fallback.count) == (3))
        #expect((fallback.map(\.rank)) == ([1, 2, 3]))
        #expect(fallback.allSatisfy { $0.decision == .accept })
    }

    @Test
    func testTrimmerKeepsHookAndCutsTailOverSixtySeconds() {
        // Слова каждые 10 секунд: диапазон из 10 слов = 90+ секунд.
        var words: [MappedTranscriptWord] = []
        for index in 0..<10 {
            let time = Double(index) * 10
            words.append(
                MappedTranscriptWord(
                    wordID: "w\(index)", text: "слово", clipID: UUID(), sourceID: UUID(),
                    sourceStart: time, sourceEnd: time + 0.5,
                    timelineStart: time, timelineEnd: time + 0.5, confidence: 0.9))
        }
        let trimmed = ShortsWindowPlanner.trimmedToMaxDuration(words[...])
        #expect((trimmed) != nil)
        // Хук (начало) сохранён, хвост обрезан по потолку 60 секунд.
        #expect((trimmed!.first!.wordID) == ("w0"))
        #expect((trimmed!.last!.sourceEnd - trimmed!.first!.sourceStart) <= (ShortsLimits.maxDuration))
    }

    @Test
    func testQwenRepairsBrokenShortsResponseOnce() async throws {
        ShortsMockURLProtocol.configure(responses: [
            .json(content: "это не json"),
            .json(
                content: """
                    {"schema_version":1,"clips":[{"id":"s1","first_word_id":"w000001","last_word_id":"w000002","title":"приветствие","reason":"яркое начало","confidence":0.9}]}
                    """),
        ])
        let client = OpenRouterClient(session: makeMockSession())
        let result = try await client.proposeShorts(words: words, model: .qwen, apiKey: "secret")
        #expect((result.clips.map(\.id)) == (["s1"]))
        #expect((ShortsMockURLProtocol.recordedRequests.count) == (2))
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

    @Test
    func testWindowPlannerMakesSingleWindowForShortVideo() {
        let windows = ShortsWindowPlanner.windows(for: mappedWords(count: 20, step: 1))
        #expect((windows.count) == (1))
        #expect((windows.first) == (0..<20))
    }

    @Test
    func testWindowPlannerCoversAllWordsWithOverlapForLongVideo() {
        // 40 минут речи: слово каждые 10 секунд.
        let words = mappedWords(count: 240, step: 10)
        let windows = ShortsWindowPlanner.windows(for: words)
        #expect((windows.count) > (1))
        #expect((windows.first?.lowerBound) == (0))
        #expect((windows.last?.upperBound) == (words.count))
        // Каждое слово накрыто хотя бы одним окном.
        var covered = Set<Int>()
        for window in windows { covered.formUnion(window) }
        #expect((covered.count) == (words.count))
        // Соседние окна пересекаются — моменты на стыке не теряются.
        for pair in zip(windows, windows.dropFirst()) {
            #expect((pair.0.upperBound) > (pair.1.lowerBound))
        }
    }

    private func makeCandidate(
        rank: Int, title: String, start: Double, end: Double,
        pattern: String = ""
    ) -> ShortCandidate {
        ShortCandidate(
            id: UUID(), rank: rank, title: title, reason: "", hook: "",
            pattern: pattern, excerpt: "", start: start, end: end,
            confidence: 0.9, hookScore: 8, standaloneScore: 8,
            payoffScore: 8, pacingScore: 8, enabled: false)
    }

    @Test
    func testDeduplicationKeepsHigherRankedOverlappingCandidate() {
        let candidates = [
            makeCandidate(rank: 1, title: "сильный", start: 10, end: 40),
            makeCandidate(rank: 2, title: "пересекается", start: 30, end: 55),
            makeCandidate(rank: 3, title: "отдельный", start: 100, end: 120),
        ]
        let deduplicated = ShortsWindowPlanner.deduplicated(candidates)
        #expect((deduplicated.map(\.title)) == (["сильный", "отдельный"]))
    }

    @Test
    func testDiversityKeepsAtMostTwoPerPattern() {
        // Три «мнения» и одна «история»: сильнейшие два мнения остаются.
        let candidates = [
            makeCandidate(rank: 1, title: "мнение 1", start: 0, end: 30, pattern: "мнение"),
            makeCandidate(rank: 2, title: "мнение 2", start: 40, end: 70, pattern: "мнение"),
            makeCandidate(rank: 3, title: "мнение 3", start: 80, end: 110, pattern: "мнение"),
            makeCandidate(rank: 4, title: "история", start: 120, end: 150, pattern: "история"),
            makeCandidate(rank: 5, title: "без паттерна 1", start: 160, end: 190),
            makeCandidate(rank: 6, title: "без паттерна 2", start: 200, end: 230),
            makeCandidate(rank: 7, title: "без паттерна 3", start: 240, end: 270),
        ]
        let diversified = ShortsCutService.diversified(candidates)
        #expect(
            (diversified.map(\.title)) == (["мнение 1", "мнение 2", "история", "без паттерна 1", "без паттерна 2"]))
    }

    // MARK: - Границы

    private func boundaryWords(start: Double, end: Double) -> (first: MappedTranscriptWord, last: MappedTranscriptWord)
    {
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

    @Test
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

        guard let boundary else {
            Issue.record("Граница не нашлась")
            return
        }
        // Старт — тихая точка в 0.2 сек воздуха до слова, конец — в 0.35 после.
        #expect(abs((boundary.start) - (4.8)) <= (0.06))
        #expect(abs((boundary.end) - (8.85)) <= (0.06))
    }

    @Test
    func testBoundaryResolverFallsBackToAirWhenNoSilence() {
        let (first, last) = boundaryWords(start: 5.0, end: 8.5)
        let samples = Int(20 * WaveformStore.windowsPerSecond)
        let peaks = [Float](repeating: 0.5, count: samples)

        let boundary = ShortsBoundaryResolver.resolve(
            first: first, last: last, peaks: peaks,
            sourceDuration: 20, thresholdDB: -40)

        #expect((boundary) != nil)
        #expect(abs((boundary!.start) - (4.9)) <= (0.001))
        #expect(abs((boundary!.end) - (8.65)) <= (0.001))
    }

    @Test
    func testBoundaryResolverClampsToSourceStart() {
        let (first, last) = boundaryWords(start: 0.05, end: 3.0)
        let boundary = ShortsBoundaryResolver.resolve(
            first: first, last: last, peaks: [],
            sourceDuration: 10, thresholdDB: -40)
        #expect((boundary) != nil)
        #expect((boundary!.start) >= (0))
    }

    // MARK: - Промпты и имена файлов

    @Test
    func testPromptsTreatDataAsUntrusted() throws {
        #expect(ShortsPrompts.selectorSystem.contains("недоверенные данные"))
        #expect(ShortsPrompts.rankerSystem.contains("недоверенные данные"))
        #expect(ShortsPrompts.mapperSystem.contains("недоверенные данные"))
        #expect(ShortsPrompts.verifierSystem.contains("недоверенные данные"))
        let proposal = try ShortsPrompts.proposalUser(words: words)
        #expect(proposal.contains("DATA_TRANSCRIPT_BEGIN"))
        let rank = try ShortsPrompts.rankUser(
            proposals: [
                ShortsRankInput(
                    id: "s1", title: "т", reason: "р",
                    confidence: 0.9, durationSeconds: 20, excerpt: "текст",
                    hook: "хук", pattern: "мнение", topic: "тема",
                    hookScore: 7, standaloneScore: 8,
                    payoffScore: 9, pacingScore: 6)
            ],
            desiredCount: 3)
        #expect(rank.contains("DATA_CANDIDATES_BEGIN"))
        #expect(rank.contains("не больше 3"))
    }

    @Test
    func testPromptsCarryRubricAndVideoMap() throws {
        // Решётка оценки и хук-дисциплина — в системном промпте поиска.
        #expect(ShortsPrompts.selectorSystem.contains("hook_score"))
        #expect(ShortsPrompts.selectorSystem.contains("standalone_score"))
        #expect(ShortsPrompts.selectorSystem.contains("payoff_score"))
        #expect(ShortsPrompts.selectorSystem.contains("pacing_score"))
        #expect(ShortsPrompts.selectorSystem.contains("Никогда не бери"))
        // Карта видео — недоверенные данные во всех пользовательских промптах.
        let map = try ShortsPrompts.mapUser(words: words)
        #expect(map.contains("DATA_TRANSCRIPT_BEGIN"))
        let withMap = try ShortsPrompts.proposalUser(words: words, videoMap: "[00:00–01:00] тест")
        #expect(withMap.contains("DATA_VIDEO_MAP_BEGIN"))
        #expect(withMap.contains("[00:00–01:00] тест"))
        let rankWithMap = try ShortsPrompts.rankUser(
            proposals: [], desiredCount: nil, videoMap: "карта")
        #expect(rankWithMap.contains("DATA_VIDEO_MAP_BEGIN"))
        let verify = try ShortsPrompts.verifyUser(inputs: [], videoMap: "карта")
        #expect(verify.contains("DATA_CANDIDATES_BEGIN"))
        #expect(verify.contains("DATA_VIDEO_MAP_BEGIN"))
        // Разнообразие — в системном промпте отбора.
        #expect(ShortsPrompts.rankerSystem.contains("одну тему"))
    }

    // MARK: - Контракты карты и вердиктов

    @Test
    func testMapDecoderFiltersPeaksWithUnknownWords() throws {
        let envelope = try OpenRouterClient.decodeShortsMap(
            """
            {"schema_version":1,"summary":"о чём кусок","peaks":[{"first_word_id":"w000001","last_word_id":"w000002","what":"главный тезис"},{"first_word_id":"unknown","last_word_id":"w000002","what":"битый"},{"first_word_id":"w000003","last_word_id":"w000001","what":"перевёрнут"}]}
            """, words: words)
        #expect((envelope.summary) == ("о чём кусок"))
        #expect((envelope.peaks.map(\.what)) == (["главный тезис"]))
    }

    @Test
    func testMapDecoderRejectsBrokenEnvelope() {
        #expect(throws: (any Error).self) {
            try OpenRouterClient.decodeShortsMap("не json", words: words)
        }
    }

    @Test
    func testVerdictDecoderFiltersUnknownAndDuplicateCandidates() throws {
        let inputs = [
            ShortsVerifyInput(
                id: "s1", title: "т", hook: "хук", pattern: "мнение",
                durationSeconds: 20, excerpt: "текст",
                hookScore: 7, standaloneScore: 8, payoffScore: 9, pacingScore: 6),
            ShortsVerifyInput(
                id: "s2", title: "т", hook: "хук", pattern: "история",
                durationSeconds: 25, excerpt: "текст",
                hookScore: 6, standaloneScore: 7, payoffScore: 8, pacingScore: 5),
        ]
        let envelope = try OpenRouterClient.decodeShortsVerdicts(
            """
            {"schema_version":1,"verdicts":[{"clip_id":"sX","keep":true,"verdict":"неизвестный"},{"clip_id":"s1","keep":false,"verdict":"начало скучное"},{"clip_id":"s1","keep":true,"verdict":"дубль"},{"clip_id":"s2","keep":true,"verdict":"держит внимание"}]}
            """, inputs: inputs)
        #expect((envelope.verdicts.count) == (2))
        #expect((envelope.verdicts.first?.keep) == (false))
    }

    @Test
    func testFileNameSanitizesTitleAndAvoidsCollisions() throws {
        #expect((ShortsExporter.sanitize("Привет: мир? *звёздочка*")) == ("Привет мир звёздочка"))
        #expect((ShortsExporter.sanitize("///")) == ("ролик"))

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("shorts-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let first = ShortsExporter.fileURL(in: folder, sourceName: "подкаст", index: 0, title: "инсайт")
        FileManager.default.createFile(atPath: first.path, contents: Data())
        let second = ShortsExporter.fileURL(in: folder, sourceName: "подкаст", index: 0, title: "инсайт")
        #expect((first.lastPathComponent) == ("подкаст 01 инсайт.mp4"))
        #expect((second.lastPathComponent) == ("подкаст 01 инсайт (2).mp4"))
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
            return Response(
                status: 200,
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
        let response = HTTPURLResponse(
            url: request.url!, statusCode: value.status,
            httpVersion: nil, headerFields: value.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: value.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
