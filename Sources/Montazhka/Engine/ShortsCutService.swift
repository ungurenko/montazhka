import Foundation
import OSLog

/// Нарезка длинного видео на shorts: расшифровка → оконные предложения ИИ →
/// отбор и ранжирование → тихие границы. Работает с одним исходником.
actor ShortsCutService {
    private let transcriptStore: any TranscriptProviding
    private let ai: any ShortsAIServing
    private let waveforms: any WaveformProviding

    init(
        transcriptStore: any TranscriptProviding,
        ai: any ShortsAIServing,
        waveforms: any WaveformProviding
    ) {
        self.transcriptStore = transcriptStore
        self.ai = ai
        self.waveforms = waveforms
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

        let mapResult = try await makeVideoMap(
            windows: windows,
            words: timelineMap.words,
            configuration: configuration,
            status: status)
        if let warning = mapResult.warning { warnings.append(warning) }
        let videoMap = mapResult.value
        try Task.checkCancellation()

        // Проход 1: предложения по каждому окну с картой всего видео в
        // контексте. Ошибка одного окна (таймаут, битый ответ после ремонта)
        // не губит весь анализ — работаем с теми окнами, что отвечают.
        var contexts: [String: ProposalContext] = [:]
        var ordered: [ShortsProposalDTO] = []
        var failedWindows = 0
        var lastWindowError: Error?
        for (index, window) in windows.enumerated() {
            try Task.checkCancellation()
            await status(.searching(done: index, total: windows.count))
            let windowWords = timelineMap.words[window]
            do {
                let envelope = try await ai.proposeShorts(
                    words: windowWords.map(\.publicPayload),
                    configuration: configuration,
                    videoMap: videoMap)
                for proposal in envelope.clips {
                    // Модель любит одинаковые ID в каждом окне (clip_1…),
                    // а кандидаты разных окон должны быть уникальны.
                    let uniqueID = "w\(index)-\(proposal.id)"
                    guard contexts[uniqueID] == nil,
                        let range = timelineMap.range(
                            firstWordID: proposal.firstWordID,
                            lastWordID: proposal.lastWordID),
                        let trimmed = ShortsWindowPlanner.trimmedToMaxDuration(range),
                        let first = trimmed.first, let last = trimmed.last
                    else { continue }
                    let excerpt = trimmed.map(\.text).joined(separator: " ")
                    let uniqueProposal = ShortsProposalDTO(
                        id: uniqueID,
                        firstWordID: proposal.firstWordID,
                        lastWordID: proposal.lastWordID,
                        title: proposal.title,
                        reason: proposal.reason,
                        confidence: proposal.confidence,
                        hook: proposal.hook,
                        pattern: proposal.pattern,
                        topic: proposal.topic,
                        hookScore: proposal.hookScore,
                        standaloneScore: proposal.standaloneScore,
                        payoffScore: proposal.payoffScore,
                        pacingScore: proposal.pacingScore)
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
                Logger.network.error(
                    "Shorts: окно \(index + 1)/\(windows.count) не ответило: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        guard !ordered.isEmpty else {
            if failedWindows > 0, let lastWindowError { throw lastWindowError }
            return ShortsAnalysisResult(
                candidates: [], transcript: words, warnings: warnings)
        }
        if failedWindows > 0 {
            warnings.append(
                .proposalWindowsFailed(failed: failedWindows, total: windows.count))
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
        await status(.ready)
        return ShortsAnalysisResult(
            candidates: candidates, transcript: words, warnings: warnings)
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

    private static func proposalByID(_ id: String, in proposals: [ShortsProposalDTO]) -> ShortsProposalDTO? {
        proposals.first { $0.id == id }
    }

    /// Проход 0: компактная карта всего видео. Ошибка одного окна не
    /// останавливает анализ, но возвращается пользователю предупреждением.
    private func makeVideoMap(
        windows: [Range<Int>],
        words: [MappedTranscriptWord],
        configuration: AIRequestConfiguration,
        status: @escaping @Sendable (ShortsStatus) async -> Void
    ) async throws -> (value: String, warning: ShortsAnalysisWarning?) {
        var mapLines: [String] = []
        var failedWindows = 0
        for (index, window) in windows.enumerated() {
            try Task.checkCancellation()
            await status(.mapping(done: index, total: windows.count))
            let windowWords = words[window]
            do {
                let map = try await ai.mapShortsWindow(
                    words: windowWords.map(\.publicPayload),
                    configuration: configuration)
                if let line = Self.mapLine(for: map, windowWords: windowWords) {
                    mapLines.append(line)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failedWindows += 1
                Logger.network.error(
                    "Shorts: карта окна \(index + 1)/\(windows.count) не собралась: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        let warning =
            failedWindows > 0
            ? ShortsAnalysisWarning.mapWindowsFailed(
                failed: failedWindows,
                total: windows.count)
            : nil
        return (mapLines.joined(separator: "\n"), warning)
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

    private struct ProposalContext: Sendable {
        let first: MappedTranscriptWord
        let last: MappedTranscriptWord
        let excerpt: String
        let duration: Double
    }
}
