import Foundation
import Testing

@testable import MontazhkaKit

@Suite
struct ShortsAnalysisCacheTests {
    @Test
    func keyChangesWithTranscriptModelAndEffort() {
        let words = mappedWords(count: 5)
        let base = ShortsAnalysisCache.key(words: words, configuration: openRouterConfiguration)

        var edited = words
        edited[2] = MappedTranscriptWord(
            wordID: edited[2].wordID, text: "другое", clipID: edited[2].clipID,
            sourceID: edited[2].sourceID, sourceStart: edited[2].sourceStart,
            sourceEnd: edited[2].sourceEnd, timelineStart: edited[2].timelineStart,
            timelineEnd: edited[2].timelineEnd, confidence: edited[2].confidence)

        #expect(ShortsAnalysisCache.key(words: edited, configuration: openRouterConfiguration) != base)
        #expect(
            ShortsAnalysisCache.key(
                words: words,
                configuration: .openRouter(model: .luna, effort: nil, apiKey: "test")) != base)
        #expect(
            ShortsAnalysisCache.key(
                words: words,
                configuration: .openRouter(model: .qwen, effort: "high", apiKey: "test")) != base)
        #expect(
            ShortsAnalysisCache.key(
                words: words,
                configuration: .codexCLI(
                    modelID: SmartEditModel.qwen.rawValue, effort: nil,
                    executable: URL(fileURLWithPath: "/usr/bin/true"))) != base)
        // Ключ от секрета не зависит: пользователь сменил ключ — кэш остаётся.
        #expect(
            ShortsAnalysisCache.key(
                words: words,
                configuration: .openRouter(model: .qwen, effort: nil, apiKey: "другой")) == base)
    }

    @Test
    func secondAnalysisSkipsMapAndSearchButStillRanks() async throws {
        let root = cacheDirectory("hit")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = MediaReference(path: "/tmp/shorts-cache.mov")
        let words = transcriptWords(sourceID: source.id, count: 921)
        let router = CountingShortsRouter()

        for _ in 0..<2 {
            _ = try await makeService(router: router, words: words, cacheDir: root)
                .analyze(
                    source: source, sourceDuration: 921, count: .three,
                    configuration: openRouterConfiguration, thresholdDB: -40,
                    status: { _ in })
        }

        let counts = await router.counts
        #expect(counts.map == 2)  // только первый прогон
        #expect(counts.propose == 2)
        #expect(counts.rank == 2)  // отбор зависит от количества роликов — всегда
        #expect(counts.verify == 2)
    }

    @Test
    func partialAnalysisIsNotCached() async throws {
        let root = cacheDirectory("partial")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = MediaReference(path: "/tmp/shorts-partial.mov")
        let words = transcriptWords(sourceID: source.id, count: 921)
        let router = CountingShortsRouter(failProposalForWindowStarting: "w000871")

        for _ in 0..<2 {
            _ = try await makeService(router: router, words: words, cacheDir: root)
                .analyze(
                    source: source, sourceDuration: 921, count: .three,
                    configuration: openRouterConfiguration, thresholdDB: -40,
                    status: { _ in })
        }

        let counts = await router.counts
        #expect(counts.map == 4)
        #expect(counts.propose == 4)
    }

    @Test
    func parallelWindowsKeepProposalOrder() async throws {
        let root = cacheDirectory("order")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = MediaReference(path: "/tmp/shorts-order.mov")
        let words = transcriptWords(sourceID: source.id, count: 921)
        // Первое окно отвечает медленнее второго: без сортировки по индексу
        // предложения перемешались бы.
        let router = CountingShortsRouter(slowProposalForWindowStarting: "w000001")

        _ = try await makeService(router: router, words: words, cacheDir: root)
            .analyze(
                source: source, sourceDuration: 921, count: .three,
                configuration: openRouterConfiguration, thresholdDB: -40,
                status: { _ in })

        let ranked = await router.rankedIDs
        #expect(ranked == ["w0-candidate", "w1-candidate"])
    }

    // MARK: - Вспомогательное

    private func makeService(
        router: CountingShortsRouter, words: [TranscriptWord], cacheDir: URL
    ) -> ShortsCutService {
        ShortsCutService(
            transcriptStore: CacheTestTranscriptProvider(words: words),
            ai: router,
            waveforms: CacheTestWaveformProvider(),
            cache: ShortsAnalysisCache(cacheDir: cacheDir))
    }

    private func cacheDirectory(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-shorts-cache-\(label)-\(UUID().uuidString)")
    }

    private func transcriptWords(sourceID: UUID, count: Int) -> [TranscriptWord] {
        (0..<count).map { index in
            TranscriptWord(
                sourceID: sourceID, text: "слово\(index)",
                start: Double(index), end: Double(index) + 0.4, confidence: 0.99)
        }
    }

    private func mappedWords(count: Int) -> [MappedTranscriptWord] {
        let id = UUID()
        return (0..<count).map { index in
            MappedTranscriptWord(
                wordID: String(format: "w%06d", index + 1), text: "слово\(index)",
                clipID: id, sourceID: id,
                sourceStart: Double(index), sourceEnd: Double(index) + 0.4,
                timelineStart: Double(index), timelineEnd: Double(index) + 0.4,
                confidence: 0.99)
        }
    }
}

/// Считает обращения к ИИ и умеет ронять или задерживать конкретное окно.
private actor CountingShortsRouter: ShortsAIServing {
    struct Counts: Sendable {
        var map = 0
        var propose = 0
        var rank = 0
        var verify = 0
    }

    private(set) var counts = Counts()
    private(set) var rankedIDs: [String] = []
    private let failProposalForWindowStarting: String?
    private let slowProposalForWindowStarting: String?

    init(
        failProposalForWindowStarting: String? = nil,
        slowProposalForWindowStarting: String? = nil
    ) {
        self.failProposalForWindowStarting = failProposalForWindowStarting
        self.slowProposalForWindowStarting = slowProposalForWindowStarting
    }

    func ensureModelAvailable(_ configuration: AIRequestConfiguration) {}

    func mapShortsWindow(
        words: [OpenRouterTranscriptWord], configuration: AIRequestConfiguration
    ) -> ShortsMapEnvelope {
        counts.map += 1
        return ShortsMapEnvelope(schemaVersion: 1, summary: "Часть видео", peaks: [])
    }

    func proposeShorts(
        words: [OpenRouterTranscriptWord], configuration: AIRequestConfiguration,
        videoMap: String
    ) async throws -> ShortsProposalEnvelope {
        counts.propose += 1
        let first = words[0]
        if first.id == failProposalForWindowStarting { throw CacheTestError.expectedFailure }
        if first.id == slowProposalForWindowStarting {
            try await Task.sleep(for: .milliseconds(60))
        }
        let last = words.first { $0.end - first.start >= 20 } ?? words[words.count - 1]
        return ShortsProposalEnvelope(
            schemaVersion: 1,
            clips: [
                ShortsProposalDTO(
                    id: "candidate", firstWordID: first.id, lastWordID: last.id,
                    title: "Сильный момент", reason: "Самостоятельная мысль", confidence: 0.95,
                    hook: "Начало", pattern: "мнение", topic: "тест",
                    hookScore: 8, standaloneScore: 8, payoffScore: 8, pacingScore: 8)
            ])
    }

    func rankShorts(
        proposals: [ShortsRankInput], desiredCount: Int?,
        configuration: AIRequestConfiguration, videoMap: String
    ) -> ShortsRankingEnvelope {
        counts.rank += 1
        rankedIDs = proposals.map(\.id)
        return ShortsRankingEnvelope(
            schemaVersion: 1,
            decisions: proposals.enumerated().map { index, proposal in
                ShortsRankDTO(
                    clipID: proposal.id, decision: .accept, rank: index + 1,
                    title: proposal.title, reason: proposal.reason, confidence: 0.9)
            })
    }

    func verifyShorts(
        inputs: [ShortsVerifyInput], videoMap: String,
        configuration: AIRequestConfiguration
    ) -> ShortsVerdictEnvelope {
        counts.verify += 1
        return ShortsVerdictEnvelope(
            schemaVersion: 1,
            verdicts: inputs.map {
                ShortsVerdictDTO(clipID: $0.id, keep: true, verdict: "Годится")
            })
    }
}

private actor CacheTestTranscriptProvider: TranscriptProviding {
    let words: [TranscriptWord]

    init(words: [TranscriptWord]) { self.words = words }

    func ensure(
        source: MediaReference, progress: (@Sendable (Double?) async -> Void)?
    ) async throws -> [TranscriptWord] {
        words
    }

    func modelIsCached() -> Bool { true }
}

private struct CacheTestWaveformProvider: WaveformProviding {
    func ensure(path: String) async -> [Float]? { [] }
}

private enum CacheTestError: Error { case expectedFailure }

private let openRouterConfiguration = AIRequestConfiguration.openRouter(
    model: .qwen, effort: nil, apiKey: "test")
