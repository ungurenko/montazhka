import Foundation

/// Узкие контракты позволяют проверять координацию AI-сервисов без сети,
/// загрузки модели распознавания и декодирования настоящего видео.
protocol TranscriptProviding: Sendable {
    func ensure(
        source: MediaReference,
        progress: (@Sendable (Double?) async -> Void)?
    ) async throws -> [TranscriptWord]

    func modelIsCached() async -> Bool
}

protocol WaveformProviding: Sendable {
    func ensure(path: String) async -> [Float]?
}

protocol SmartEditAIServing: Sendable {
    func ensureModelAvailable(_ configuration: AIRequestConfiguration) async throws
    func propose(
        words: [OpenRouterTranscriptWord], configuration: AIRequestConfiguration
    ) async throws -> ProposalEnvelope
    func review(
        words: [OpenRouterTranscriptWord], proposals: ProposalEnvelope,
        configuration: AIRequestConfiguration
    ) async throws -> ReviewEnvelope
}

protocol ShortsAIServing: Sendable {
    func ensureModelAvailable(_ configuration: AIRequestConfiguration) async throws
    func mapShortsWindow(
        words: [OpenRouterTranscriptWord], configuration: AIRequestConfiguration
    ) async throws -> ShortsMapEnvelope
    func proposeShorts(
        words: [OpenRouterTranscriptWord], configuration: AIRequestConfiguration,
        videoMap: String
    ) async throws -> ShortsProposalEnvelope
    func rankShorts(
        proposals: [ShortsRankInput], desiredCount: Int?,
        configuration: AIRequestConfiguration,
        videoMap: String
    ) async throws -> ShortsRankingEnvelope
    func verifyShorts(
        inputs: [ShortsVerifyInput], videoMap: String,
        configuration: AIRequestConfiguration
    ) async throws -> ShortsVerdictEnvelope
}

extension TranscriptStore: TranscriptProviding {}
extension WaveformStore: WaveformProviding {}
