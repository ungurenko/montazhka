import Foundation
import OSLog

/// Нарезка длинного видео на shorts: расшифровка → оконные предложения ИИ →
/// отбор и ранжирование → тихие границы. Работает с одним исходником.
actor ShortsCutService {
    private let transcriptStore: any TranscriptProviding
    private let ai: any ShortsAIServing
    private let waveforms: any WaveformProviding
    private let cache: ShortsAnalysisCache?

    init(
        transcriptStore: any TranscriptProviding,
        ai: any ShortsAIServing,
        waveforms: any WaveformProviding,
        cache: ShortsAnalysisCache? = nil
    ) {
        self.transcriptStore = transcriptStore
        self.ai = ai
        self.waveforms = waveforms
        self.cache = cache
    }

    func analyze(
        source: MediaReference,
        sourceDuration: Double,
        count: ShortsCount,
        configuration: AIRequestConfiguration,
        thresholdDB: Double,
        status: @escaping @Sendable (ShortsStatus) async -> Void
    ) async throws -> ShortsAnalysisResult {
        guard sourceDuration >= ShortsLimits.minSourceDuration else { throw ShortsError.tooShort }

        try await ai.ensureModelAvailable(configuration)
        let cached = await transcriptStore.modelIsCached()
        if !cached { await status(.preparingModel(progress: nil)) }

        let words = try await transcriptStore.ensure(source: source) { progress in
            await status(.transcribing(progress: progress))
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
        var warnings: [ShortsAnalysisWarning] = []

        let search = try await searchCandidates(
            windows: windows, timelineMap: timelineMap,
            configuration: configuration, status: status)
        warnings.append(contentsOf: search.warnings)
        let videoMap = search.videoMap
        let ordered = search.proposals
        let contexts = search.contexts
        guard !ordered.isEmpty else {
            if let error = search.lastError { throw error }
            return ShortsAnalysisResult(
                candidates: [], transcript: words, warnings: warnings)
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
                excerpt: String((context?.excerpt ?? "").prefix(700)),
                hook: proposal.hook, pattern: proposal.pattern, topic: proposal.topic,
                hookScore: proposal.hookScore, standaloneScore: proposal.standaloneScore,
                payoffScore: proposal.payoffScore, pacingScore: proposal.pacingScore)
        }
        let decisions: [ShortsRankDTO]
        do {
            let ranking = try await ai.rankShorts(
                proposals: rankInputs, desiredCount: count.desired,
                configuration: configuration, videoMap: videoMap)
            decisions = ranking.decisions
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Logger.network.error(
                "Shorts: отбор недоступен, фолбэк по порядку предложений: \(error.localizedDescription, privacy: .public)"
            )
            warnings.append(.rankingFallback)
            decisions = Self.fallbackDecisions(proposals: ordered, desiredCount: count.desired)
        }
        try Task.checkCancellation()

        // Проход 3: тест холодного зрителя. Пропущенный кандидатом вердикт
        // трактуем как «оставить»; ошибка прохода целиком — фолбэк на
        // ранжированный список без верификации.
        await status(.verifying)
        let accepted = Self.acceptedInRankOrder(decisions)
        var rejectedIDs = Set<String>()
        if !accepted.isEmpty {
            let verifyInputs: [ShortsVerifyInput] = accepted.compactMap { decision in
                guard let proposal = Self.proposalByID(decision.clipID, in: ordered),
                    let context = contexts[decision.clipID]
                else { return nil }
                return ShortsVerifyInput(
                    id: proposal.id, title: decision.title,
                    hook: proposal.hook, pattern: proposal.pattern,
                    durationSeconds: max(0, context.duration),
                    excerpt: String(context.excerpt.prefix(700)),
                    hookScore: proposal.hookScore, standaloneScore: proposal.standaloneScore,
                    payoffScore: proposal.payoffScore, pacingScore: proposal.pacingScore)
            }
            do {
                let envelope = try await ai.verifyShorts(
                    inputs: verifyInputs, videoMap: videoMap,
                    configuration: configuration)
                rejectedIDs = Set(envelope.verdicts.filter { !$0.keep }.map(\.clipID))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Logger.network.error(
                    "Shorts: проверка недоступна, оставляю решения отбора: \(error.localizedDescription, privacy: .public)"
                )
                warnings.append(.verificationSkipped)
            }
        }

        var candidates: [ShortCandidate] = []
        for decision in accepted where !rejectedIDs.contains(decision.clipID) {
            guard let proposal = Self.proposalByID(decision.clipID, in: ordered),
                let context = contexts[decision.clipID]
            else { continue }
            guard
                let boundary = ShortsBoundaryResolver.resolve(
                    first: context.first, last: context.last, peaks: peaks,
                    sourceDuration: sourceDuration, thresholdDB: thresholdDB)
            else { continue }
            let confidence = min(proposal.confidence, decision.confidence)
            candidates.append(
                ShortCandidate(
                    id: UUID(), rank: candidates.count + 1,
                    title: decision.title, reason: decision.reason,
                    hook: proposal.hook, pattern: proposal.pattern,
                    excerpt: context.excerpt,
                    start: boundary.start, end: boundary.end,
                    confidence: confidence,
                    hookScore: proposal.hookScore,
                    standaloneScore: proposal.standaloneScore,
                    payoffScore: proposal.payoffScore,
                    pacingScore: proposal.pacingScore,
                    enabled: false))
        }

        candidates = ShortsWindowPlanner.deduplicated(candidates)
        candidates = Self.diversified(candidates)
        candidates = Array(candidates.prefix(ShortsLimits.maxCandidates))
        candidates = Self.preselected(candidates, count: count)
        await status(.ready)
        return ShortsAnalysisResult(
            candidates: candidates, transcript: words, warnings: warnings)
    }

    // MARK: - Проходы 0 и 1

    private struct CandidateSearch {
        let videoMap: String
        let proposals: [ShortsProposalDTO]
        let contexts: [String: ProposalContext]
        let warnings: [ShortsAnalysisWarning]
        /// Ошибка последнего молчавшего окна: нужна, только если кандидатов нет вовсе.
        let lastError: Error?
    }

    /// Карта видео и предложения по окнам — самая дорогая часть анализа и
    /// единственная, которая не зависит от запрошенного количества роликов.
    /// Поэтому результат берётся из кэша целиком либо считается целиком.
    private func searchCandidates(
        windows: [Range<Int>],
        timelineMap: TranscriptTimelineMap,
        configuration: AIRequestConfiguration,
        status: @escaping @Sendable (ShortsStatus) async -> Void
    ) async throws -> CandidateSearch {
        let key = ShortsAnalysisCache.key(
            words: timelineMap.words, configuration: configuration)
        if let document = await cache?.load(key: key) {
            await status(.mapping(done: windows.count, total: windows.count))
            await status(.searching(done: windows.count, total: windows.count))
            let resolved = Self.resolveContexts(
                proposals: document.proposals, timelineMap: timelineMap)
            return CandidateSearch(
                videoMap: document.videoMap, proposals: resolved.proposals,
                contexts: resolved.contexts, warnings: [], lastError: nil)
        }

        var warnings: [ShortsAnalysisWarning] = []

        // Проход 0: компактная карта всего видео. Ошибка одного окна не
        // останавливает анализ, но возвращается пользователю предупреждением.
        let ai = self.ai
        let words = timelineMap.words
        let mapRun = try await Self.runWindows(
            count: windows.count,
            limit: configuration.maxConcurrentWindows,
            status: { done in await status(.mapping(done: done, total: windows.count)) },
            work: { index in
                let windowWords = words[windows[index]]
                let map = try await ai.mapShortsWindow(
                    words: windowWords.map(\.publicPayload),
                    configuration: configuration)
                return Self.mapLine(for: map, windowWords: windowWords)
            })
        if mapRun.failed > 0 {
            warnings.append(
                .mapWindowsFailed(failed: mapRun.failed, total: windows.count))
        }
        let videoMap = mapRun.values.compactMap { $0 ?? nil }.joined(separator: "\n")
        try Task.checkCancellation()

        // Проход 1: предложения по каждому окну с картой всего видео в
        // контексте. Ошибка одного окна (таймаут, битый ответ после ремонта)
        // не губит весь анализ — работаем с теми окнами, что отвечают.
        let proposalRun = try await Self.runWindows(
            count: windows.count,
            limit: configuration.maxConcurrentWindows,
            status: { done in await status(.searching(done: done, total: windows.count)) },
            work: { index in
                let windowWords = words[windows[index]]
                return try await ai.proposeShorts(
                    words: windowWords.map(\.publicPayload),
                    configuration: configuration,
                    videoMap: videoMap)
            })
        if proposalRun.failed > 0 {
            warnings.append(
                .proposalWindowsFailed(failed: proposalRun.failed, total: windows.count))
        }

        // Модель любит одинаковые ID в каждом окне (clip_1…), а кандидаты
        // разных окон должны быть уникальны.
        var raw: [ShortsProposalDTO] = []
        for (index, envelope) in proposalRun.values.enumerated() {
            guard let envelope else { continue }
            raw.append(contentsOf: envelope.clips.map { $0.prefixed(with: "w\(index)-") })
        }
        let resolved = Self.resolveContexts(proposals: raw, timelineMap: timelineMap)

        // Частичный анализ не консервируем: иначе молчание одного окна
        // навсегда обеднит результат для этого видео.
        if mapRun.failed == 0, proposalRun.failed == 0, !resolved.proposals.isEmpty {
            await cache?.store(
                ShortsAnalysisCacheDocument(videoMap: videoMap, proposals: resolved.proposals),
                key: key)
        }

        return CandidateSearch(
            videoMap: videoMap, proposals: resolved.proposals,
            contexts: resolved.contexts, warnings: warnings,
            lastError: proposalRun.lastError)
    }

    private struct WindowRun<Value: Sendable>: Sendable {
        let values: [Value?]
        let failed: Int
        let lastError: (any Error)?
    }

    /// Окна независимы, поэтому опрашиваются пачками параллельно. Порядок
    /// результатов сохраняется по индексу окна, отмена пробрасывается наружу,
    /// а ошибки отдельных окон копятся — анализ переживает молчание одного.
    private static func runWindows<Value: Sendable>(
        count: Int,
        limit: Int,
        status: @escaping @Sendable (Int) async -> Void,
        work: @escaping @Sendable (Int) async throws -> Value
    ) async throws -> WindowRun<Value> {
        var values = [Value?](repeating: nil, count: count)
        var failed = 0
        var lastError: (any Error)?
        let batchSize = max(1, limit)

        await status(0)
        for batchStart in stride(from: 0, to: count, by: batchSize) {
            try Task.checkCancellation()
            let batchEnd = min(batchStart + batchSize, count)
            let results = await withTaskGroup(of: (Int, Result<Value, any Error>).self) { group in
                for index in batchStart..<batchEnd {
                    group.addTask {
                        do { return (index, .success(try await work(index))) } catch {
                            return (index, .failure(error))
                        }
                    }
                }
                var collected: [(Int, Result<Value, any Error>)] = []
                for await result in group { collected.append(result) }
                return collected
            }
            for (index, result) in results.sorted(by: { $0.0 < $1.0 }) {
                switch result {
                case .success(let value):
                    values[index] = value
                case .failure(let error):
                    if error is CancellationError { throw CancellationError() }
                    failed += 1
                    lastError = error
                    Logger.network.error(
                        "Shorts: окно \(index + 1)/\(count) не ответило: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            await status(batchEnd)
        }
        return WindowRun(values: values, failed: failed, lastError: lastError)
    }

    /// Диапазон слов каждого предложения превращается в контекст кандидата.
    /// Общий шаг для свежего анализа и для загрузки из кэша: предложения
    /// с неразрешимыми ID слов отбрасываются одинаково.
    private static func resolveContexts(
        proposals: [ShortsProposalDTO],
        timelineMap: TranscriptTimelineMap
    ) -> (proposals: [ShortsProposalDTO], contexts: [String: ProposalContext]) {
        var contexts: [String: ProposalContext] = [:]
        var ordered: [ShortsProposalDTO] = []
        for proposal in proposals {
            guard contexts[proposal.id] == nil,
                let range = timelineMap.range(
                    firstWordID: proposal.firstWordID,
                    lastWordID: proposal.lastWordID),
                let trimmed = ShortsWindowPlanner.trimmedToMaxDuration(range),
                let first = trimmed.first, let last = trimmed.last
            else { continue }
            contexts[proposal.id] = ProposalContext(
                first: first, last: last,
                excerpt: trimmed.map(\.text).joined(separator: " "),
                duration: last.sourceEnd - first.sourceStart)
            ordered.append(proposal)
        }
        return (ordered, contexts)
    }

    // MARK: - Отбор

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
    static func fallbackDecisions(
        proposals: [ShortsProposalDTO],
        desiredCount: Int?
    ) -> [ShortsRankDTO] {
        let limit = min(desiredCount ?? ShortsLimits.maxCandidates, ShortsLimits.maxCandidates)
        return proposals.prefix(limit).enumerated().map { index, proposal in
            ShortsRankDTO(
                clipID: proposal.id, decision: .accept, rank: index + 1,
                title: proposal.title, reason: proposal.reason,
                confidence: proposal.confidence)
        }
    }

    /// Разнообразие: не больше двух роликов на один паттерн. Вход должен быть
    /// отсортирован по силе — в каждом паттерне остаются сильнейшие.
    static func diversified(_ candidates: [ShortCandidate]) -> [ShortCandidate] {
        let perPatternLimit = 2
        var counts: [String: Int] = [:]
        return candidates.filter { candidate in
            let key = candidate.pattern.isEmpty ? "без паттерна" : candidate.pattern
            let count = counts[key, default: 0]
            guard count < perPatternLimit else { return false }
            counts[key] = count + 1
            return true
        }
    }

    /// Галочки на top-N по рангу: один клик — и лучшее уже выбрано. Живёт в
    /// сервисе, а не в экране: агентная нарезка отбирает ролики по этому же
    /// признаку и без предвыбора получала пустой список.
    static func preselected(_ candidates: [ShortCandidate], count: ShortsCount) -> [ShortCandidate] {
        var result = candidates
        let limit = count.desired ?? result.count
        for index in result.indices {
            result[index].enabled = index < limit
        }
        return result
    }

    private static func proposalByID(_ id: String, in proposals: [ShortsProposalDTO]) -> ShortsProposalDTO? {
        proposals.first { $0.id == id }
    }

    /// Компактная строка карты для контекста других проходов: время — о чём
    /// кусок — пики. Без JSON, только сущности и тайминги.
    private static func mapLine(
        for map: ShortsMapEnvelope,
        windowWords: ArraySlice<MappedTranscriptWord>
    ) -> String? {
        guard let first = windowWords.first, let last = windowWords.last,
            !map.summary.isEmpty
        else { return nil }
        var line = "[\(clock(first.sourceStart))–\(clock(last.sourceEnd))] \(map.summary)"
        let wordsByID = Dictionary(uniqueKeysWithValues: windowWords.map { ($0.wordID, $0) })
        let peaks = map.peaks.compactMap { peak -> String? in
            guard let word = wordsByID[peak.firstWordID] else { return nil }
            return "\(clock(word.sourceStart)) \(peak.what)"
        }
        if !peaks.isEmpty {
            line += " Пики: " + peaks.joined(separator: "; ") + "."
        }
        return line
    }

    private static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    struct ProposalContext: Sendable {
        let first: MappedTranscriptWord
        let last: MappedTranscriptWord
        let excerpt: String
        let duration: Double
    }
}
