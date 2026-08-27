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

protocol SmartEditOpenRouterServing: Sendable {
    func ensureModelAvailable(_ model: SmartEditModel, apiKey: String) async throws
    func propose(
        words: [OpenRouterTranscriptWord], model: SmartEditModel,
        effort: String?, apiKey: String
    ) async throws -> ProposalEnvelope
    func review(
        words: [OpenRouterTranscriptWord], proposals: ProposalEnvelope,
        model: SmartEditModel, effort: String?, apiKey: String
    ) async throws -> ReviewEnvelope
}

protocol ShortsOpenRouterServing: Sendable {
    func ensureModelAvailable(_ model: SmartEditModel, apiKey: String) async throws
    func mapShortsWindow(
        words: [OpenRouterTranscriptWord], model: SmartEditModel,
        effort: String?, apiKey: String
    ) async throws -> ShortsMapEnvelope
    func proposeShorts(
        words: [OpenRouterTranscriptWord], model: SmartEditModel,
        effort: String?, apiKey: String, videoMap: String
    ) async throws -> ShortsProposalEnvelope
    func rankShorts(
        proposals: [ShortsRankInput], desiredCount: Int?,
        model: SmartEditModel, effort: String?, apiKey: String,
        videoMap: String
    ) async throws -> ShortsRankingEnvelope
    func verifyShorts(
        inputs: [ShortsVerifyInput], videoMap: String,
        model: SmartEditModel, effort: String?, apiKey: String
    ) async throws -> ShortsVerdictEnvelope
}

extension TranscriptStore: TranscriptProviding {}
extension WaveformStore: WaveformProviding {}
extension OpenRouterClient: SmartEditOpenRouterServing, ShortsOpenRouterServing {}
