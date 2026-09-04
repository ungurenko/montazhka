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
        try await run(AIPasses.proposals(words: words), configuration: configuration)
    }

    func review(
        words: [OpenRouterTranscriptWord],
        proposals: ProposalEnvelope,
        configuration: AIRequestConfiguration
    ) async throws -> ReviewEnvelope {
        try await run(
            AIPasses.reviews(words: words, proposals: proposals), configuration: configuration)
    }

    func mapShortsWindow(
        words: [OpenRouterTranscriptWord],
        configuration: AIRequestConfiguration
    ) async throws -> ShortsMapEnvelope {
        try await run(AIPasses.shortsMap(words: words), configuration: configuration)
    }

    func proposeShorts(
        words: [OpenRouterTranscriptWord],
        configuration: AIRequestConfiguration,
        videoMap: String
    ) async throws -> ShortsProposalEnvelope {
        try await run(
            AIPasses.shortsProposals(words: words, videoMap: videoMap),
            configuration: configuration)
    }

    func rankShorts(
        proposals: [ShortsRankInput],
        desiredCount: Int?,
        configuration: AIRequestConfiguration,
        videoMap: String
    ) async throws -> ShortsRankingEnvelope {
        try await run(
            AIPasses.shortsRanking(
                proposals: proposals, desiredCount: desiredCount, videoMap: videoMap),
            configuration: configuration)
    }

    func verifyShorts(
        inputs: [ShortsVerifyInput],
        videoMap: String,
        configuration: AIRequestConfiguration
    ) async throws -> ShortsVerdictEnvelope {
        try await run(
            AIPasses.shortsVerdicts(inputs: inputs, videoMap: videoMap),
            configuration: configuration)
    }

    /// Один и тот же проход уходит либо в OpenRouter, либо в CLI-агента.
    /// CLI-агенты не знают про схемы ответа и чинят сломанный JSON всегда.
    private func run<Value: Sendable>(
        _ pass: AIPass<Value>,
        configuration: AIRequestConfiguration
    ) async throws -> Value {
        if case .openRouter(let model, let effort, let apiKey) = configuration {
            return try await openRouter.run(pass, model: model, effort: effort, apiKey: apiKey)
        }
        let content = try await cli.complete(
            system: pass.system, user: pass.user, configuration: configuration)
        do {
            return try pass.decode(content)
        } catch {
            let repaired = try await cli.complete(
                system: SmartEditPrompts.repairSystem,
                user: SmartEditPrompts.repairUser(content, contract: pass.schema.contract),
                configuration: configuration)
            return try pass.decode(repaired)
        }
    }
}
