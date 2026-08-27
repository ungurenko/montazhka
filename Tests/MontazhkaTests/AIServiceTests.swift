import Foundation
import Testing

@testable import MontazhkaKit

@Suite
struct AIServiceTests {
    @Test
    func smartEditProgressNeverMovesBackToAnEarlierStage() async throws {
        let source = MediaReference(path: "/tmp/smart-edit.mov")
        let words = transcriptWords(sourceID: source.id, count: 20)
        let service = SmartEditService(
            transcriptStore: StubTranscriptProvider(words: words, modelCached: false),
            ai: StubSmartEditRouter(),
            waveforms: StubWaveformProvider())
        let recorder = SmartEditStatusRecorder()

        _ = try await service.analyze(
            clips: [Clip(source: source, start: 0, end: 20)],
            projectThresholdDB: -40,
            configuration: testAIConfiguration,
            status: { await recorder.append($0) })

        let stages = await recorder.values.map(smartEditStage)
        #expect(stages == stages.sorted())
        #expect(stages.contains(0))
        #expect(stages.contains(2))
        #expect(stages.last == 5)
    }

    @Test
    func smartEditCancellationStopsWhileTranscribing() async throws {
        let source = MediaReference(path: "/tmp/cancel-smart-edit.mov")
        let service = SmartEditService(
            transcriptStore: SuspendedTranscriptProvider(),
            ai: StubSmartEditRouter(),
            waveforms: StubWaveformProvider())
        let task = Task {
            try await service.analyze(
                clips: [Clip(source: source, start: 0, end: 20)],
                projectThresholdDB: -40,
                configuration: testAIConfiguration,
                status: { _ in })
        }

        await Task.yield()
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test
    func shortsReportsPartialWindowsAndFallbackPasses() async throws {
        let source = MediaReference(path: "/tmp/shorts.mov")
        let words = transcriptWords(sourceID: source.id, count: 921)
        let service = ShortsCutService(
            transcriptStore: StubTranscriptProvider(words: words, modelCached: false),
            ai: PartiallyFailingShortsRouter(),
            waveforms: StubWaveformProvider())
        let recorder = ShortsStatusRecorder()

        let result = try await service.analyze(
            source: source,
            sourceDuration: 921,
            count: ShortsCount.three,
            configuration: testAIConfiguration,
            thresholdDB: -40,
            status: { await recorder.append($0) })

        #expect(result.candidates.count == 1)
        #expect(
            result.warnings.contains(
                ShortsAnalysisWarning.mapWindowsFailed(failed: 1, total: 2)))
        #expect(
            result.warnings.contains(
                ShortsAnalysisWarning.proposalWindowsFailed(failed: 1, total: 2)))
        #expect(result.warnings.contains(ShortsAnalysisWarning.rankingFallback))
        #expect(result.warnings.contains(ShortsAnalysisWarning.verificationSkipped))

        let stages = await recorder.values.map(shortsStage)
        #expect(stages == stages.sorted())
        #expect(stages.last == 7)
    }

    private func transcriptWords(sourceID: UUID, count: Int) -> [TranscriptWord] {
        (0..<count).map { index in
            TranscriptWord(
                sourceID: sourceID,
                text: "слово\(index)",
                start: Double(index),
                end: Double(index) + 0.4,
                confidence: 0.99)
        }
    }

    private func smartEditStage(_ status: SmartEditStatus) -> Int {
        switch status {
        case .preparingModel: 0
        case .transcribing: 1
        case .proposing: 2
        case .reviewing: 3
        case .preparingCuts: 4
        case .ready: 5
        case .idle, .failed: -1
        }
    }

    private func shortsStage(_ status: ShortsStatus) -> Int {
        switch status {
        case .preparingModel: 0
        case .transcribing: 1
        case .mapping: 2
        case .searching: 3
        case .ranking: 4
        case .verifying: 5
        case .ready: 7
        case .idle, .failed: -1
        }
    }
}

private actor StubTranscriptProvider: TranscriptProviding {
    let words: [TranscriptWord]
    let modelCached: Bool

    init(words: [TranscriptWord], modelCached: Bool) {
        self.words = words
        self.modelCached = modelCached
    }

    func ensure(
        source: MediaReference,
        progress: (@Sendable (Double?) async -> Void)?
    ) async throws -> [TranscriptWord] {
        await progress?(0.2)
        await progress?(0.8)
        await progress?(1)
        return words
    }

    func modelIsCached() -> Bool { modelCached }
}

private actor SuspendedTranscriptProvider: TranscriptProviding {
    func ensure(
        source: MediaReference,
        progress: (@Sendable (Double?) async -> Void)?
    ) async throws -> [TranscriptWord] {
        await progress?(0.2)
        try await Task.sleep(for: .seconds(10))
        return []
    }

    func modelIsCached() -> Bool { true }
}

private struct StubWaveformProvider: WaveformProviding {
    func ensure(path: String) async -> [Float]? { [] }
}

private actor StubSmartEditRouter: SmartEditAIServing {
    func ensureModelAvailable(_ configuration: AIRequestConfiguration) {}

    func propose(
        words: [OpenRouterTranscriptWord], configuration: AIRequestConfiguration
    ) -> ProposalEnvelope {
        ProposalEnvelope(schemaVersion: 1, edits: [])
    }

    func review(
        words: [OpenRouterTranscriptWord], proposals: ProposalEnvelope,
        configuration: AIRequestConfiguration
    ) -> ReviewEnvelope {
        ReviewEnvelope(schemaVersion: 1, decisions: [])
    }
}

private actor PartiallyFailingShortsRouter: ShortsAIServing {
    private var mapCalls = 0
    private var proposalCalls = 0

    func ensureModelAvailable(_ configuration: AIRequestConfiguration) {}

    func mapShortsWindow(
        words: [OpenRouterTranscriptWord], configuration: AIRequestConfiguration
    ) throws -> ShortsMapEnvelope {
        mapCalls += 1
        if mapCalls == 1 { throw StubAIError.expectedFailure }
        return ShortsMapEnvelope(schemaVersion: 1, summary: "Тестовая часть", peaks: [])
    }

    func proposeShorts(
        words: [OpenRouterTranscriptWord], configuration: AIRequestConfiguration,
        videoMap: String
    ) throws -> ShortsProposalEnvelope {
        proposalCalls += 1
        if proposalCalls == 2 { throw StubAIError.expectedFailure }
        let first = words[0]
        let last = words.first { $0.end - first.start >= 15 } ?? words[words.count - 1]
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
        configuration: AIRequestConfiguration,
        videoMap: String
    ) throws -> ShortsRankingEnvelope {
        throw StubAIError.expectedFailure
    }

    func verifyShorts(
        inputs: [ShortsVerifyInput], videoMap: String,
        configuration: AIRequestConfiguration
    ) throws -> ShortsVerdictEnvelope {
        throw StubAIError.expectedFailure
    }
}

private actor SmartEditStatusRecorder {
    private(set) var values: [SmartEditStatus] = []
    func append(_ value: SmartEditStatus) { values.append(value) }
}

private actor ShortsStatusRecorder {
    private(set) var values: [ShortsStatus] = []
    func append(_ value: ShortsStatus) { values.append(value) }
}

private enum StubAIError: Error {
    case expectedFailure
}

private let testAIConfiguration = AIRequestConfiguration.openRouter(
    model: .qwen,
    effort: nil,
    apiKey: "test")
