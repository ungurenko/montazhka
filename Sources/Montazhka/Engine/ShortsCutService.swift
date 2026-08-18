import Foundation
import OSLog

/// Нарезка длинного видео на shorts: расшифровка → оконные предложения ИИ →
/// отбор и ранжирование → тихие границы. Работает с одним исходником.
actor ShortsCutService {
    private let transcriptStore: TranscriptStore
    private let openRouter: OpenRouterClient
    private let waveforms: WaveformStore

    init(transcriptStore: TranscriptStore, openRouter: OpenRouterClient,
         waveforms: WaveformStore) {
        self.transcriptStore = transcriptStore
        self.openRouter = openRouter
        self.waveforms = waveforms
    }

    func analyze(source: MediaReference,
                 sourceDuration: Double,
                 count: ShortsCount,
                 model: SmartEditModel, apiKey: String,
                 thresholdDB: Double,
                 status: @escaping @Sendable (ShortsStatus) async -> Void) async throws -> [ShortCandidate] {
        guard sourceDuration >= ShortsLimits.minSourceDuration else { throw ShortsError.tooShort }

        try await openRouter.ensureModelAvailable(model, apiKey: apiKey)
        let cached = await transcriptStore.modelIsCached()
        if !cached { await status(.preparingModel(progress: nil)) }

        let words = try await transcriptStore.ensure(source: source) { progress in
            Task { await status(.transcribing(progress: progress)) }
        }
        guard !words.isEmpty else { throw ShortsError.emptyTranscript }

        // Один исходник = один клип на всю длину: координаты ленты совпадают
        // с секундами файла, что нужно для прямой нарезки.
        let clip = Clip(source: source, start: 0, end: sourceDuration)
        let timelineMap = TranscriptTimelineMapper.make(clips: [clip], transcripts: words)
        guard !timelineMap.words.isEmpty else { throw ShortsError.emptyTranscript }

        let peaks = await waveforms.ensure(path: clip.sourcePath) ?? []
        try Task.checkCancellation()

        let windows = ShortsWindowPlanner.windows(for: timelineMap.words)
        guard !windows.isEmpty else { throw ShortsError.emptyTranscript }

        // Проход 1: предложения по каждому окну. Ошибка одного окна (таймаут,
        // битый ответ после ремонта) не губит весь анализ — работаем с теми
        // окнами, что отвечают.
        var contexts: [String: ProposalContext] = [:]
        var ordered: [ShortsProposalDTO] = []
        var failedWindows = 0
        var lastWindowError: Error?
        for (index, window) in windows.enumerated() {
            try Task.checkCancellation()
            await status(.searching(done: index, total: windows.count))
            let windowWords = timelineMap.words[window]
            do {
                let envelope = try await openRouter.proposeShorts(
                    words: windowWords.map(\.publicPayload), model: model, apiKey: apiKey)
                for proposal in envelope.clips {
                    // Модель любит одинаковые ID в каждом окне (clip_1…),
                    // а кандидаты разных окон должны быть уникальны.
                    let uniqueID = "w\(index)-\(proposal.id)"
                    guard contexts[uniqueID] == nil,
                          let range = timelineMap.range(firstWordID: proposal.firstWordID,
                                                        lastWordID: proposal.lastWordID),
                          let trimmed = ShortsWindowPlanner.trimmedToMaxDuration(range),
                          let first = trimmed.first, let last = trimmed.last else { continue }
                    let excerpt = trimmed.map(\.text).joined(separator: " ")
                    let uniqueProposal = ShortsProposalDTO(
                        id: uniqueID,
                        firstWordID: proposal.firstWordID,
                        lastWordID: proposal.lastWordID,
                        title: proposal.title,
                        reason: proposal.reason,
                        confidence: proposal.confidence)
                    contexts[uniqueID] = ProposalContext(
                        first: first, last: last, excerpt: excerpt,
                        duration: last.sourceEnd - first.sourceStart)
                    ordered.append(uniqueProposal)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failedWindows += 1
                lastWindowError = error
                Logger.network.error("Shorts: окно \(index + 1)/\(windows.count) не ответило: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard !ordered.isEmpty else {
            if failedWindows > 0, let lastWindowError { throw lastWindowError }
            return []
        }
        try Task.checkCancellation()

        // Проход 2: отбор по сводкам, без полного транскрипта — вызов компактный.
        // Если отбор недоступен, фолбэк — предложения как есть: проход 1 уже
        // отобрал их по критериям сильного ролика.
        await status(.ranking)
        let rankInputs = ordered.map { proposal -> ShortsRankInput in
            let context = contexts[proposal.id]
            return ShortsRankInput(
                id: proposal.id, title: proposal.title, reason: proposal.reason,
                confidence: proposal.confidence,
                durationSeconds: max(0, context?.duration ?? 0),
                excerpt: String((context?.excerpt ?? "").prefix(700)))
        }
        let decisions: [ShortsRankDTO]
        do {
            let ranking = try await openRouter.rankShorts(
                proposals: rankInputs, desiredCount: count.desired,
                model: model, apiKey: apiKey)
            decisions = ranking.decisions
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Logger.network.error("Shorts: отбор недоступен, фолбэк по порядку предложений: \(error.localizedDescription, privacy: .public)")
            decisions = Self.fallbackDecisions(proposals: ordered, desiredCount: count.desired)
        }
        try Task.checkCancellation()

        var candidates: [ShortCandidate] = []
        let proposalByID = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0) })
        for decision in Self.acceptedInRankOrder(decisions) {
            guard let proposal = proposalByID[decision.clipID],
                  let context = contexts[decision.clipID] else { continue }
            guard let boundary = ShortsBoundaryResolver.resolve(
                first: context.first, last: context.last, peaks: peaks,
                sourceDuration: sourceDuration, thresholdDB: thresholdDB) else { continue }
            let confidence = min(proposal.confidence, decision.confidence)
            candidates.append(ShortCandidate(
                id: UUID(), rank: candidates.count + 1,
                title: decision.title, reason: decision.reason,
                excerpt: context.excerpt,
                start: boundary.start, end: boundary.end,
                confidence: confidence, enabled: false))
        }

        candidates = ShortsWindowPlanner.deduplicated(candidates)
        candidates = Array(candidates.prefix(ShortsLimits.maxCandidates))
        await status(.ready)
        return candidates
    }

    /// Принятые решения в порядке силы: валидный ранг важнее порядка ответа,
    /// битая нумерация (rank<1) опускает решение в хвост по порядку ответа.
    static func acceptedInRankOrder(_ decisions: [ShortsRankDTO]) -> [ShortsRankDTO] {
        let accepted = decisions.enumerated().filter { $0.element.decision == .accept }
        return accepted.sorted { lhs, rhs in
            let leftRank = lhs.element.rank >= 1 ? lhs.element.rank : Int.max
            let rightRank = rhs.element.rank >= 1 ? rhs.element.rank : Int.max
            if leftRank != rightRank { return leftRank < rightRank }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// Фолбэк, когда проход-отбор недоступен: принимаем предложения по порядку.
    static func fallbackDecisions(proposals: [ShortsProposalDTO],
                                  desiredCount: Int?) -> [ShortsRankDTO] {
        let limit = min(desiredCount ?? ShortsLimits.maxCandidates, ShortsLimits.maxCandidates)
        return proposals.prefix(limit).enumerated().map { index, proposal in
            ShortsRankDTO(clipID: proposal.id, decision: .accept, rank: index + 1,
                          title: proposal.title, reason: proposal.reason,
                          confidence: proposal.confidence)
        }
    }

    private struct ProposalContext: Sendable {
        let first: MappedTranscriptWord
        let last: MappedTranscriptWord
        let excerpt: String
        let duration: Double
    }
}
