import Foundation
import OSLog

enum OpenRouterError: LocalizedError, Equatable {
    case invalidKey
    case insufficientBalance
    case modelUnavailable
    case rateLimited(wait: Int?)
    case providerUnavailable
    case timeout
    case damagedResponse
    case network(String)

    var errorDescription: String? {
        switch self {
        case .invalidKey: return "Ключ OpenRouter не подходит. Проверь его и сохрани снова."
        case .insufficientBalance: return "На балансе OpenRouter закончились средства."
        case .modelUnavailable: return "Выбранная модель сейчас недоступна в OpenRouter."
        case .rateLimited(let wait):
            return wait.map { "OpenRouter просит подождать \($0) секунд." }
                ?? "OpenRouter временно ограничил число запросов. Попробуй чуть позже."
        case .providerUnavailable: return "Провайдер модели временно недоступен. Попробуй ещё раз."
        case .timeout: return "OpenRouter не ответил за три минуты. Попробуй ещё раз."
        case .damagedResponse: return "ИИ вернул повреждённый ответ. Попробуй ещё раз."
        case .network(let message): return "Не удалось связаться с OpenRouter: \(message)"
        }
    }
}

struct ProposalEnvelope: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let edits: [ProposalDTO]
    enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", edits }
}

struct ProposalDTO: Codable, Equatable, Sendable {
    let id: String
    let kind: SmartEditKind
    let firstWordID: String
    let lastWordID: String
    let reason: String
    let confidence: Double
    enum CodingKeys: String, CodingKey {
        case id, kind, reason, confidence
        case firstWordID = "first_word_id"
        case lastWordID = "last_word_id"
    }
}

struct ReviewEnvelope: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let decisions: [ReviewDTO]
    enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", decisions }
}

struct ReviewDTO: Codable, Equatable, Sendable {
    let editID: String
    let decision: SmartEditReview.Decision
    let firstWordID: String
    let lastWordID: String
    let reason: String
    let confidence: Double
    enum CodingKeys: String, CodingKey {
        case decision, reason, confidence
        case editID = "edit_id"
        case firstWordID = "first_word_id"
        case lastWordID = "last_word_id"
    }
}

actor OpenRouterClient {
    private let session: URLSession
    private let baseURL = URL(string: "https://openrouter.ai/api/v1")!
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(session: URLSession = .shared) {
        self.session = session
    }

    func validateKey(_ apiKey: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("key"))
        authorize(&request, key: apiKey)
        _ = try await data(for: request, retry: false)
    }

    func ensureModelAvailable(_ model: SmartEditModel, apiKey: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        authorize(&request, key: apiKey)
        let data = try await data(for: request, retry: true)
        let catalog = try decoder.decode(ModelCatalog.self, from: data)
        guard catalog.data.contains(where: { $0.id == model.rawValue }) else {
            throw OpenRouterError.modelUnavailable
        }
    }

    func propose(words: [OpenRouterTranscriptWord], model: SmartEditModel,
                 apiKey: String) async throws -> ProposalEnvelope {
        let user = try SmartEditPrompts.proposalUser(words: words)
        let content = try await chat(model: model, apiKey: apiKey,
                                     system: SmartEditPrompts.editorSystem,
                                     user: user, schema: .proposals)
        do { return try Self.decodeProposals(content, words: words) }
        catch where model == .qwen {
            let repaired = try await chat(model: model, apiKey: apiKey,
                                          system: "Ты исправляешь только JSON-формат.",
                                          user: SmartEditPrompts.repairUser(content, contract: "proposal_schema_v1"),
                                          schema: .jsonObject)
            return try Self.decodeProposals(repaired, words: words)
        }
    }

    func review(words: [OpenRouterTranscriptWord], proposals: ProposalEnvelope,
                model: SmartEditModel, apiKey: String) async throws -> ReviewEnvelope {
        let user = try SmartEditPrompts.reviewUser(words: words, proposals: proposals)
        let content = try await chat(model: model, apiKey: apiKey,
                                     system: SmartEditPrompts.reviewerSystem,
                                     user: user, schema: .reviews)
        do { return try Self.decodeReviews(content, proposals: proposals, words: words) }
        catch where model == .qwen {
            let repaired = try await chat(model: model, apiKey: apiKey,
                                          system: "Ты исправляешь только JSON-формат.",
                                          user: SmartEditPrompts.repairUser(content, contract: "review_schema_v1"),
                                          schema: .jsonObject)
            return try Self.decodeReviews(repaired, proposals: proposals, words: words)
        }
    }

    /// Нарезка на shorts, проход 1: предложения по одному окну транскрипта.
    func proposeShorts(words: [OpenRouterTranscriptWord], model: SmartEditModel,
                       apiKey: String) async throws -> ShortsProposalEnvelope {
        let user = try ShortsPrompts.proposalUser(words: words)
        let content = try await chat(model: model, apiKey: apiKey,
                                     system: ShortsPrompts.selectorSystem,
                                     user: user, schema: .shortsProposals,
                                     reasoningEffort: "low")
        do { return try Self.decodeShortsProposals(content, words: words) }
        catch is CancellationError {
            throw CancellationError()
        } catch {
            // Модели иногда заворачивают JSON в markdown или эхо-обёртку —
            // чиним отдельным вызовом независимо от модели.
            let repaired = try await chat(model: model, apiKey: apiKey,
                                          system: "Ты исправляешь только JSON-формат.",
                                          user: SmartEditPrompts.repairUser(content, contract: "shorts_clips_schema_v1"),
                                          schema: .jsonObject,
                                          reasoningEffort: "low")
            return try Self.decodeShortsProposals(repaired, words: words)
        }
    }

    /// Нарезка на shorts, проход 2: отбор и ранжирование кандидатов по сводкам.
    func rankShorts(proposals: [ShortsRankInput], desiredCount: Int?,
                    model: SmartEditModel, apiKey: String) async throws -> ShortsRankingEnvelope {
        let user = try ShortsPrompts.rankUser(proposals: proposals, desiredCount: desiredCount)
        let content = try await chat(model: model, apiKey: apiKey,
                                     system: ShortsPrompts.rankerSystem,
                                     user: user, schema: .shortsRanking,
                                     reasoningEffort: "low")
        do { return try Self.decodeShortsRanking(content, proposals: proposals) }
        catch is CancellationError {
            throw CancellationError()
        } catch {
            let repaired = try await chat(model: model, apiKey: apiKey,
                                          system: "Ты исправляешь только JSON-формат.",
                                          user: SmartEditPrompts.repairUser(content, contract: "shorts_decisions_schema_v1"),
                                          schema: .jsonObject,
                                          reasoningEffort: "low")
            return try Self.decodeShortsRanking(repaired, proposals: proposals)
        }
    }

    private enum OutputSchema { case proposals, reviews, jsonObject, shortsProposals, shortsRanking }

    private func chat(model: SmartEditModel, apiKey: String, system: String,
                      user: String, schema: OutputSchema,
                      reasoningEffort: String? = nil) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request, key: apiKey)
        request.httpBody = try encoder.encode(ChatRequest(
            model: model.rawValue,
            messages: [.init(role: "system", content: system), .init(role: "user", content: user)],
            provider: .init(dataCollection: "deny", requireParameters: true, allowFallbacks: true),
            responseFormat: responseFormat(for: schema, strict: model.usesStrictSchema),
            reasoning: reasoningEffort.map { ChatRequest.Reasoning(effort: $0) }
        ))
        let data = try await data(for: request, retry: true)
        guard let content = try decoder.decode(ChatResponse.self, from: data).choices.first?.message.content,
              !content.isEmpty else { throw OpenRouterError.damagedResponse }
        return content
    }

    private func data(for request: URLRequest, retry: Bool) async throws -> Data {
        var request = request
        request.timeoutInterval = 120
        for attempt in 0...(retry ? 1 : 0) {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw OpenRouterError.damagedResponse }
                if 200..<300 ~= http.statusCode { return data }
                let wait = retryAfter(http)
                if [429, 502, 503, 504].contains(http.statusCode), attempt == 0 {
                    if let wait, wait > 10 { throw OpenRouterError.rateLimited(wait: wait) }
                    if let wait, wait > 0 {
                        try await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000)
                    }
                    continue
                }
                throw mapStatus(http.statusCode, retryAfter: wait)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as OpenRouterError {
                throw error
            } catch let error as URLError where error.code == .timedOut {
                throw OpenRouterError.timeout
            } catch {
                Logger.network.error("OpenRouter: \(error.localizedDescription)")
                throw OpenRouterError.network(error.localizedDescription)
            }
        }
        throw OpenRouterError.providerUnavailable
    }

    private func authorize(_ request: inout URLRequest, key: String) {
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("Монтажка", forHTTPHeaderField: "X-Title")
    }

    private func retryAfter(_ response: HTTPURLResponse) -> Int? {
        response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
    }

    private func mapStatus(_ status: Int, retryAfter: Int?) -> OpenRouterError {
        switch status {
        case 401, 403: return .invalidKey
        case 402: return .insufficientBalance
        case 404: return .modelUnavailable
        case 429: return .rateLimited(wait: retryAfter)
        case 502, 503, 504: return .providerUnavailable
        default: return .damagedResponse
        }
    }

    static func decodeProposals(_ content: String,
                                words: [OpenRouterTranscriptWord]) throws -> ProposalEnvelope {
        let decoder = JSONDecoder()
        let wordIndices = try validatedWordIndices(words)
        guard let data = content.data(using: .utf8),
              let envelope = try? decoder.decode(ProposalEnvelope.self, from: data),
              envelope.schemaVersion == 1,
              Set(envelope.edits.map(\.id)).count == envelope.edits.count,
              envelope.edits.allSatisfy({
                  !$0.id.isEmpty && !$0.reason.isEmpty && (0...1).contains($0.confidence) &&
                      validRange(first: $0.firstWordID, last: $0.lastWordID,
                                 wordIndices: wordIndices) != nil
              })
        else { throw OpenRouterError.damagedResponse }
        return envelope
    }

    static func decodeReviews(_ content: String,
                              proposals: ProposalEnvelope,
                              words: [OpenRouterTranscriptWord]) throws -> ReviewEnvelope {
        let decoder = JSONDecoder()
        let wordIndices = try validatedWordIndices(words)
        guard Set(proposals.edits.map(\.id)).count == proposals.edits.count else {
            throw OpenRouterError.damagedResponse
        }
        let proposalsByID = Dictionary(uniqueKeysWithValues: proposals.edits.map { ($0.id, $0) })
        guard let data = content.data(using: .utf8),
              let envelope = try? decoder.decode(ReviewEnvelope.self, from: data),
              envelope.schemaVersion == 1,
              Set(envelope.decisions.map(\.editID)).count == envelope.decisions.count,
              envelope.decisions.allSatisfy({ review in
                  guard let proposal = proposalsByID[review.editID],
                        !review.reason.isEmpty,
                        (0...1).contains(review.confidence),
                        let proposalRange = validRange(
                            first: proposal.firstWordID, last: proposal.lastWordID,
                            wordIndices: wordIndices),
                        let reviewRange = validRange(
                            first: review.firstWordID, last: review.lastWordID,
                            wordIndices: wordIndices)
                  else { return false }
                  return reviewRange.lowerBound >= proposalRange.lowerBound &&
                      reviewRange.upperBound <= proposalRange.upperBound
              })
        else { throw OpenRouterError.damagedResponse }
        return envelope
    }

    /// Ленентный декодер: структурно битый JSON — ошибка, а отдельные
    /// невалидные клипы просто отфильтровываются, чтобы одно слабое место
    /// ответа не губило всё окно. Длительность здесь не проверяется — длинные
    /// фрагменты позже ужимает сервис.
    static func decodeShortsProposals(_ content: String,
                                      words: [OpenRouterTranscriptWord]) throws -> ShortsProposalEnvelope {
        let decoder = JSONDecoder()
        guard let data = Self.extractedEnvelopeData(content),
              let envelope = try? decoder.decode(ShortsProposalEnvelope.self, from: data),
              envelope.schemaVersion == 1 else {
            Logger.network.error("Shorts proposals: повреждённый ответ: \(content.prefix(400), privacy: .public)")
            throw OpenRouterError.damagedResponse
        }
        let wordTimes = try validatedWordIndices(words)
        var seenIDs = Set<String>()
        let clips = envelope.clips.filter { clip in
            seenIDs.insert(clip.id).inserted &&
                !clip.id.isEmpty && !clip.title.isEmpty && !clip.reason.isEmpty &&
                (0...1).contains(clip.confidence) &&
                validRange(first: clip.firstWordID, last: clip.lastWordID,
                           wordIndices: wordTimes) != nil
        }
        return ShortsProposalEnvelope(schemaVersion: 1, clips: clips)
    }

    /// Ленентный декодер отбора: неизвестные и повторные кандидаты отбрасываются,
    /// правила рангов нормализует сервис — модели иногда путают нумерацию.
    static func decodeShortsRanking(_ content: String,
                                    proposals: [ShortsRankInput]) throws -> ShortsRankingEnvelope {
        let decoder = JSONDecoder()
        let proposalIDs = Set(proposals.map(\.id))
        guard !proposalIDs.isEmpty,
              let data = Self.extractedEnvelopeData(content),
              let envelope = try? decoder.decode(ShortsRankingEnvelope.self, from: data),
              envelope.schemaVersion == 1 else {
            Logger.network.error("Shorts decisions: повреждённый ответ: \(content.prefix(400), privacy: .public)")
            throw OpenRouterError.damagedResponse
        }
        var seenIDs = Set<String>()
        let decisions = envelope.decisions.filter { decision in
            seenIDs.insert(decision.clipID).inserted &&
                proposalIDs.contains(decision.clipID) &&
                !decision.title.isEmpty && !decision.reason.isEmpty &&
                (0...1).contains(decision.confidence)
        }
        return ShortsRankingEnvelope(schemaVersion: 1, decisions: decisions)
    }

    /// Модели иногда заворачивают JSON в markdown-ограждения или повторяют
    /// обёртку запроса («name» + «schema»). Вытаскиваем полезный JSON, чтобы
    /// не тратить ремонтный вызов на такие случаи.
    static func extractedEnvelopeData(_ content: String) -> Data? {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            var lines = text.components(separatedBy: .newlines)
            lines.removeFirst()
            if let last = lines.last, last.trimmingCharacters(in: .whitespaces) == "```" {
                lines.removeLast()
            }
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = text.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return data }
        if let dict = object as? [String: Any] {
            for key in ["schema", "json_schema", "jsonSchema"] where dict["schema_version"] == nil {
                if let inner = dict[key], JSONSerialization.isValidJSONObject(inner),
                   let innerData = try? JSONSerialization.data(withJSONObject: inner) {
                    return innerData
                }
            }
        }
        return data
    }

    private static func validatedWordIndices(
        _ words: [OpenRouterTranscriptWord]
    ) throws -> [String: Int] {
        guard !words.isEmpty else { throw OpenRouterError.damagedResponse }
        var indices: [String: Int] = [:]
        for (index, word) in words.enumerated() {
            guard !word.id.isEmpty, indices.updateValue(index, forKey: word.id) == nil else {
                throw OpenRouterError.damagedResponse
            }
        }
        return indices
    }

    private static func validRange(
        first: String,
        last: String,
        wordIndices: [String: Int]
    ) -> ClosedRange<Int>? {
        guard let firstIndex = wordIndices[first],
              let lastIndex = wordIndices[last],
              firstIndex <= lastIndex else { return nil }
        return firstIndex...lastIndex
    }

    private func responseFormat(for schema: OutputSchema, strict: Bool) -> ResponseFormat {
        guard strict, schema != .jsonObject else { return .init(type: "json_object", jsonSchema: nil) }
        switch schema {
        case .proposals: return .init(type: "json_schema", jsonSchema: .init(name: "smart_edit_proposals", strict: true, schema: Self.proposalSchema))
        case .reviews: return .init(type: "json_schema", jsonSchema: .init(name: "smart_edit_reviews", strict: true, schema: Self.reviewSchema))
        case .shortsProposals: return .init(type: "json_schema", jsonSchema: .init(name: "shorts_clips", strict: true, schema: Self.shortsProposalSchema))
        case .shortsRanking: return .init(type: "json_schema", jsonSchema: .init(name: "shorts_decisions", strict: true, schema: Self.shortsRankingSchema))
        case .jsonObject: return .init(type: "json_object", jsonSchema: nil)
        }
    }

    private static let proposalSchema = JSONSchema.proposals
    private static let reviewSchema = JSONSchema.reviews
    private static let shortsProposalSchema = JSONSchema.shortsProposals
    private static let shortsRankingSchema = JSONSchema.shortsRanking
}

private struct ModelCatalog: Decodable { let data: [ModelItem] }
private struct ModelItem: Decodable { let id: String }
private struct ChatResponse: Decodable {
    struct Choice: Decodable { struct Message: Decodable { let content: String? }; let message: Message }
    let choices: [Choice]
}

private struct ChatRequest: Encodable {
    struct Message: Encodable { let role: String; let content: String }
    struct Provider: Encodable {
        let dataCollection: String; let requireParameters: Bool; let allowFallbacks: Bool
        enum CodingKeys: String, CodingKey {
            case dataCollection = "data_collection", requireParameters = "require_parameters", allowFallbacks = "allow_fallbacks"
        }
    }
    /// Подсказка глубины «рассуждений» для reasoning-моделей: на творческом
    /// отборе моментов низкое усилие экономит минуты без потери качества.
    struct Reasoning: Encodable { let effort: String }
    let model: String
    let messages: [Message]
    let provider: Provider
    let responseFormat: ResponseFormat
    let reasoning: Reasoning?
    enum CodingKeys: String, CodingKey { case model, messages, provider, reasoning; case responseFormat = "response_format" }
}

private struct ResponseFormat: Encodable {
    struct Schema: Encodable { let name: String; let strict: Bool; let schema: JSONSchema }
    let type: String
    let jsonSchema: Schema?
    enum CodingKeys: String, CodingKey { case type; case jsonSchema = "json_schema" }
}

private indirect enum JSONSchema: Encodable, Sendable {
    case object(properties: [String: JSONSchema], required: [String], additionalProperties: Bool)
    case array(items: JSONSchema)
    case string(enumValues: [String]? = nil)
    case number(minimum: Double?, maximum: Double?)
    case integer(constant: Int?)

    static let proposals: JSONSchema = .object(properties: [
        "schema_version": .integer(constant: 1),
        "edits": .array(items: .object(properties: [
            "id": .string(), "kind": .string(enumValues: SmartEditKind.allCases.map(\.rawValue)),
            "first_word_id": .string(), "last_word_id": .string(), "reason": .string(),
            "confidence": .number(minimum: 0, maximum: 1)
        ], required: ["id", "kind", "first_word_id", "last_word_id", "reason", "confidence"], additionalProperties: false))
    ], required: ["schema_version", "edits"], additionalProperties: false)

    static let reviews: JSONSchema = .object(properties: [
        "schema_version": .integer(constant: 1),
        "decisions": .array(items: .object(properties: [
            "edit_id": .string(), "decision": .string(enumValues: ["accept", "reject"]),
            "first_word_id": .string(), "last_word_id": .string(), "reason": .string(),
            "confidence": .number(minimum: 0, maximum: 1)
        ], required: ["edit_id", "decision", "first_word_id", "last_word_id", "reason", "confidence"], additionalProperties: false))
    ], required: ["schema_version", "decisions"], additionalProperties: false)

    static let shortsProposals: JSONSchema = .object(properties: [
        "schema_version": .integer(constant: 1),
        "clips": .array(items: .object(properties: [
            "id": .string(), "first_word_id": .string(), "last_word_id": .string(),
            "title": .string(), "reason": .string(),
            "confidence": .number(minimum: 0, maximum: 1)
        ], required: ["id", "first_word_id", "last_word_id", "title", "reason", "confidence"], additionalProperties: false))
    ], required: ["schema_version", "clips"], additionalProperties: false)

    static let shortsRanking: JSONSchema = .object(properties: [
        "schema_version": .integer(constant: 1),
        "decisions": .array(items: .object(properties: [
            "clip_id": .string(), "decision": .string(enumValues: ["accept", "reject"]),
            "rank": .integer(constant: nil), "title": .string(), "reason": .string(),
            "confidence": .number(minimum: 0, maximum: 1)
        ], required: ["clip_id", "decision", "rank", "title", "reason", "confidence"], additionalProperties: false))
    ], required: ["schema_version", "decisions"], additionalProperties: false)

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .object(let properties, let required, let additional):
            try c.encode("object", forKey: .type); try c.encode(properties, forKey: .properties)
            try c.encode(required, forKey: .required); try c.encode(additional, forKey: .additionalProperties)
        case .array(let items): try c.encode("array", forKey: .type); try c.encode(items, forKey: .items)
        case .string(let values):
            try c.encode("string", forKey: .type); try c.encodeIfPresent(values, forKey: .enumValues)
        case .number(let minimum, let maximum):
            try c.encode("number", forKey: .type); try c.encodeIfPresent(minimum, forKey: .minimum); try c.encodeIfPresent(maximum, forKey: .maximum)
        case .integer(let constant):
            try c.encode("integer", forKey: .type); try c.encodeIfPresent(constant, forKey: .constant)
        }
    }
    private enum Keys: String, CodingKey {
        case type, properties, required, items, minimum, maximum, constant = "const"
        case additionalProperties = "additionalProperties", enumValues = "enum"
    }
}
