import Foundation

/// Схема ответа модели. Имя контракта лежит рядом со схемой: именно на него
/// ссылается просьба переписать сломанный JSON, и разойтись они не должны.
enum AIOutputSchema: Sendable {
    case proposals, reviews, shortsProposals, shortsRanking, shortsMap, shortsVerdicts

    var contract: String {
        switch self {
        case .proposals: return "proposal_schema_v1"
        case .reviews: return "review_schema_v1"
        case .shortsProposals: return "shorts_clips_schema_v1"
        case .shortsRanking: return "shorts_decisions_schema_v1"
        case .shortsMap: return "shorts_map_schema_v1"
        case .shortsVerdicts: return "shorts_verdicts_schema_v1"
        }
    }
}

/// Один проход ИИ: что просим у модели, по какой схеме и как читаем ответ.
/// Описан один раз и одинаково исполняется обоими путями — и через OpenRouter,
/// и через CLI-агента.
struct AIPass<Value: Sendable>: Sendable {
    let system: String
    let user: String
    let schema: AIOutputSchema
    /// Просить переписать сломанный JSON за любой моделью. Умный монтаж через
    /// OpenRouter чинит только за qwen: остальные модели там ошибаются редко,
    /// и лишний вызов не окупается. У CLI-агентов модель выбирает пользователь,
    /// поэтому там чинят всегда.
    let repairsEveryModel: Bool
    let decode: @Sendable (String) throws -> Value
}

/// Все проходы ИИ приложения. Единственное место, где промпт, схема и разбор
/// ответа названы вместе.
enum AIPasses {
    static func proposals(words: [OpenRouterTranscriptWord]) throws -> AIPass<ProposalEnvelope> {
        AIPass(
            system: SmartEditPrompts.editorSystem,
            user: try SmartEditPrompts.proposalUser(words: words),
            schema: .proposals,
            repairsEveryModel: false,
            decode: { try OpenRouterClient.decodeProposals($0, words: words) })
    }

    static func reviews(
        words: [OpenRouterTranscriptWord],
        proposals: ProposalEnvelope
    ) throws -> AIPass<ReviewEnvelope> {
        AIPass(
            system: SmartEditPrompts.reviewerSystem,
            user: try SmartEditPrompts.reviewUser(words: words, proposals: proposals),
            schema: .reviews,
            repairsEveryModel: false,
            decode: { try OpenRouterClient.decodeReviews($0, proposals: proposals, words: words) })
    }

    /// Проход 0 нарезки: карта окна — о чём кусок и где сильные места.
    static func shortsMap(words: [OpenRouterTranscriptWord]) throws -> AIPass<ShortsMapEnvelope> {
        AIPass(
            system: ShortsPrompts.mapperSystem,
            user: try ShortsPrompts.mapUser(words: words),
            schema: .shortsMap,
            repairsEveryModel: true,
            decode: { try OpenRouterClient.decodeShortsMap($0, words: words) })
    }

    /// Проход 1 нарезки: предложения по одному окну транскрипта. videoMap —
    /// карта всего видео, чтобы окно видело контекст соседей.
    static func shortsProposals(
        words: [OpenRouterTranscriptWord],
        videoMap: String
    ) throws -> AIPass<ShortsProposalEnvelope> {
        AIPass(
            system: ShortsPrompts.selectorSystem,
            user: try ShortsPrompts.proposalUser(words: words, videoMap: videoMap),
            schema: .shortsProposals,
            repairsEveryModel: true,
            decode: { try OpenRouterClient.decodeShortsProposals($0, words: words) })
    }

    /// Проход 2 нарезки: отбор и ранжирование кандидатов по сводкам.
    static func shortsRanking(
        proposals: [ShortsRankInput],
        desiredCount: Int?,
        videoMap: String
    ) throws -> AIPass<ShortsRankingEnvelope> {
        AIPass(
            system: ShortsPrompts.rankerSystem,
            user: try ShortsPrompts.rankUser(
                proposals: proposals, desiredCount: desiredCount, videoMap: videoMap),
            schema: .shortsRanking,
            repairsEveryModel: true,
            decode: { try OpenRouterClient.decodeShortsRanking($0, proposals: proposals) })
    }

    /// Проход 3 нарезки: «тест холодного зрителя» для отобранных роликов —
    /// слабые отсеиваются с приговором в одно предложение.
    static func shortsVerdicts(
        inputs: [ShortsVerifyInput],
        videoMap: String
    ) throws -> AIPass<ShortsVerdictEnvelope> {
        AIPass(
            system: ShortsPrompts.verifierSystem,
            user: try ShortsPrompts.verifyUser(inputs: inputs, videoMap: videoMap),
            schema: .shortsVerdicts,
            repairsEveryModel: true,
            decode: { try OpenRouterClient.decodeShortsVerdicts($0, inputs: inputs) })
    }
}
