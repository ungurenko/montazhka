import Foundation

actor UnifiedAIClient: SmartEditAIServing, ShortsAIServing {
    private let openRouter: OpenRouterClient
    private let cli: any AICompletionServing

    init(
        openRouter: OpenRouterClient = OpenRouterClient(),
        cli: any AICompletionServing = CLIAgentClient()
    ) {
        self.openRouter = openRouter
        self.cli = cli
    }

    func beginUsageTracking() async { await openRouter.resetUsage() }

    func collectedUsage() async -> AIUsage { await openRouter.collectedUsage() }

    func ensureModelAvailable(_ configuration: AIRequestConfiguration) async throws {
        switch configuration {
        case .openRouter(let model, _, let apiKey):
            try await openRouter.ensureModelAvailable(model, apiKey: apiKey)
        case .codexCLI(let modelID, _, _), .openCodeCLI(let modelID, _, _):
            guard !modelID.isEmpty else {
                throw AIProviderError.modelUnavailable(configuration.modelID)
            }
        }
    }

    func propose(
        words: [OpenRouterTranscriptWord],
        configuration: AIRequestConfiguration
    ) async throws -> ProposalEnvelope {
        if case .openRouter(let model, let effort, let apiKey) = configuration {
            return try await openRouter.propose(
                words: words, model: model, effort: effort, apiKey: apiKey)
        }
        return try await completeAndDecode(
            system: SmartEditPrompts.editorSystem,
            user: SmartEditPrompts.proposalUser(words: words),
            contract: "proposal_schema_v1",
            configuration: configuration,
            decode: { try OpenRouterClient.decodeProposals($0, words: words) })
    }

    func review(
        words: [OpenRouterTranscriptWord],
        proposals: ProposalEnvelope,
        configuration: AIRequestConfiguration
    ) async throws -> ReviewEnvelope {
        if case .openRouter(let model, let effort, let apiKey) = configuration {
            return try await openRouter.review(
                words: words, proposals: proposals, model: model,
                effort: effort, apiKey: apiKey)
        }
        return try await completeAndDecode(
            system: SmartEditPrompts.reviewerSystem,
            user: SmartEditPrompts.reviewUser(words: words, proposals: proposals),
            contract: "review_schema_v1",
            configuration: configuration,
            decode: { try OpenRouterClient.decodeReviews($0, proposals: proposals, words: words) })
    }

    func mapShortsWindow(
        words: [OpenRouterTranscriptWord],
        configuration: AIRequestConfiguration
    ) async throws -> ShortsMapEnvelope {
        if case .openRouter(let model, let effort, let apiKey) = configuration {
            return try await openRouter.mapShortsWindow(
                words: words, model: model, effort: effort, apiKey: apiKey)
        }
        return try await completeAndDecode(
            system: ShortsPrompts.mapperSystem,
            user: ShortsPrompts.mapUser(words: words),
            contract: "shorts_map_schema_v1",
            configuration: configuration,
            decode: { try OpenRouterClient.decodeShortsMap($0, words: words) })
    }

    func proposeShorts(
        words: [OpenRouterTranscriptWord],
        configuration: AIRequestConfiguration,
        videoMap: String
    ) async throws -> ShortsProposalEnvelope {
        if case .openRouter(let model, let effort, let apiKey) = configuration {
            return try await openRouter.proposeShorts(
                words: words, model: model,
                effort: effort, apiKey: apiKey, videoMap: videoMap)
        }
        return try await completeAndDecode(
            system: ShortsPrompts.selectorSystem,
            user: ShortsPrompts.proposalUser(words: words, videoMap: videoMap),
            contract: "shorts_clips_schema_v1",
            configuration: configuration,
            decode: { try OpenRouterClient.decodeShortsProposals($0, words: words) })
    }

    func rankShorts(
        proposals: [ShortsRankInput],
        desiredCount: Int?,
        configuration: AIRequestConfiguration,
        videoMap: String
    ) async throws -> ShortsRankingEnvelope {
        if case .openRouter(let model, let effort, let apiKey) = configuration {
            return try await openRouter.rankShorts(
                proposals: proposals, desiredCount: desiredCount,
                model: model, effort: effort,
                apiKey: apiKey, videoMap: videoMap)
        }
        return try await completeAndDecode(
            system: ShortsPrompts.rankerSystem,
            user: ShortsPrompts.rankUser(
                proposals: proposals, desiredCount: desiredCount, videoMap: videoMap),
            contract: "shorts_decisions_schema_v1",
            configuration: configuration,
            decode: { try OpenRouterClient.decodeShortsRanking($0, proposals: proposals) })
    }

    func verifyShorts(
        inputs: [ShortsVerifyInput],
        videoMap: String,
        configuration: AIRequestConfiguration
    ) async throws -> ShortsVerdictEnvelope {
        if case .openRouter(let model, let effort, let apiKey) = configuration {
            return try await openRouter.verifyShorts(
                inputs: inputs, videoMap: videoMap,
                model: model, effort: effort, apiKey: apiKey)
        }
        return try await completeAndDecode(
            system: ShortsPrompts.verifierSystem,
            user: ShortsPrompts.verifyUser(inputs: inputs, videoMap: videoMap),
            contract: "shorts_verdicts_schema_v1",
            configuration: configuration,
            decode: { try OpenRouterClient.decodeShortsVerdicts($0, inputs: inputs) })
    }

    private func completeAndDecode<Value>(
        system: String,
        user: String,
        contract: String,
        configuration: AIRequestConfiguration,
        decode: (String) throws -> Value
    ) async throws -> Value {
        let content = try await cli.complete(
            system: system, user: user, configuration: configuration)
        do {
            return try decode(content)
        } catch {
            let repaired = try await repair(
                content, contract: contract, configuration: configuration)
            return try decode(repaired)
        }
    }

    private func repair(
        _ content: String,
        contract: String,
        configuration: AIRequestConfiguration
    ) async throws -> String {
        return try await cli.complete(
            system: "Ты исправляешь только JSON-формат.",
            user: SmartEditPrompts.repairUser(content, contract: contract),
            configuration: configuration)
    }
}
