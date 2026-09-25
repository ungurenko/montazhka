@preconcurrency import AVFoundation
import Foundation

/// Одна операция `montazhka_apply_edits` в том виде, в каком её присылает агент.
struct AgentEditOperation: Codable, Sendable {
    struct Range: Codable, Sendable {
        let from: Double
        let to: Double
    }

    let op: String
    var ranges: [Range]?
    var at: Double?
    var clip: Int?
    var to: Int?
    var edge: String?
    var seconds: Double?
    var sourcePath: String?
    var start: Double?
    var end: Double?
    var steps: Int?
    /// `deleteWords`: номера слов и отпечаток ленты из `montazhka_transcript`.
    var words: [AgentWordRange]?
    var timeline: String?
    /// `fixWords`: правильный текст и «запомнить в словаре».
    var text: String?
    var remember: Bool?

    var isUndo: Bool { op == "undo" }
    var isWordDelete: Bool { op == "deleteWords" }
    /// Операции, которые меняют не ленту, а текст расшифровки или оформление.
    var isProjectOp: Bool { op == "fixWords" }

    init(op: String, steps: Int? = nil) {
        self.op = op
        self.steps = steps
    }

    /// Принимает и голый список операций, и объект `{"operations": [...]}`.
    static func decodeList(_ data: Data) throws -> [AgentEditOperation] {
        struct Wrapper: Decodable { let operations: [AgentEditOperation] }
        if let list = try? JSONDecoder().decode([AgentEditOperation].self, from: data) { return list }
        do {
            return try JSONDecoder().decode(Wrapper.self, from: data).operations
        } catch {
            throw AgentServiceError.invalidInput("operations не разобраны: \(error.localizedDescription)")
        }
    }

    func timelineOp() throws -> TimelineEditOp {
        func need<T>(_ value: T?, _ name: String) throws -> T {
            guard let value else { throw AgentServiceError.invalidInput("Операции \(op) нужно поле \(name).") }
            return value
        }
        switch op {
        case "delete":
            return .delete(ranges: try need(ranges, "ranges").map { TimelineRange(from: $0.from, to: $0.to) })
        case "split": return .split(at: try need(at, "at"))
        case "move": return .move(clip: try need(clip, "clip"), to: try need(to, "to"))
        case "trim":
            let edgeName = try need(edge, "edge")
            guard let trimEdge: TimelineTrimEdge = edgeName == "start" ? .start : (edgeName == "end" ? .end : nil)
            else {
                throw AgentServiceError.invalidInput("edge должен быть start или end.")
            }
            return .trim(clip: try need(clip, "clip"), edge: trimEdge, seconds: try need(seconds, "seconds"))
        case "insert":
            return .insert(
                sourcePath: URL(fileURLWithPath: try need(sourcePath, "sourcePath")).standardized.path,
                start: try need(start, "start"), end: try need(end, "end"), at: try need(at, "at"))
        default:
            throw AgentServiceError.invalidInput("Неизвестная операция: \(op).")
        }
    }
}

extension AgentService {
    func applyEdits(projectID: UUID, operations: [AgentEditOperation]) async -> AgentResponse {
        do {
            guard !operations.isEmpty else { throw AgentServiceError.invalidInput("Список operations пуст.") }
            let lock = try AgentProjectLock(projectID: projectID, directory: store.projectsDir)
            defer { withExtendedLifetime(lock) {} }
            var project = try await store.load(id: projectID)

            if operations.contains(where: \.isUndo) {
                guard operations.count == 1 else {
                    throw AgentServiceError.invalidInput("undo передаётся отдельным вызовом, без других операций.")
                }
                let steps = operations[0].steps ?? 1
                let restored = try await revisions.snapshot(projectID: projectID, steps: steps)
                project.clips = restored.clips
                project.shorts = restored.shorts
                project.music = restored.music
                project.updatedAt = Date()
                try await store.save(project)
                await revisions.drop(projectID: projectID, steps: steps)
                return try await editResponse(project, warnings: [])
            }

            // Правки по словам превращаются в delete по ходу пачки: номера слов
            // считаются по ленте на момент операции. Остальные проверяем сразу.
            let prepared = try operations.map { $0.isWordDelete || $0.isProjectOp ? nil : try $0.timelineOp() }
            var durations: [String: Double] = [:]
            let paths = Set(project.clips.map(\.sourcePath)).union(
                prepared.compactMap {
                    if case .insert(let path, _, _, _)? = $0 { path } else { nil }
                })
            for path in paths {
                guard FileManager.default.fileExists(atPath: path) else { throw AgentServiceError.missingFile(path) }
                durations[path] = try await AVURLAsset(url: URL(fileURLWithPath: path)).load(.duration).seconds
            }

            let transcriptWords = try? await cachedTranscriptWords(for: project)
            let sourceWords = transcriptWords.map { words in
                Dictionary(
                    grouping: TranscriptTimelineMapper.make(clips: project.clips, transcripts: words).words,
                    by: \.sourceID)
            }
            var warnings: [String] = []
            let previousIDs = Set(project.clips.map(\.id))
            var clips = project.clips
            for (index, operation) in operations.enumerated() {
                if operation.isProjectOp {
                    try await fixWords(operation, clips: clips)
                    continue
                }
                let op: TimelineEditOp
                if let ready = prepared[index] {
                    op = ready
                    if let sourceWords {
                        warnings += Self.wordSplitWarnings(op, index: index, clips: clips, sourceWords: sourceWords)
                    }
                } else {
                    let cuts = try await wordCuts(
                        operation, clips: clips, transcript: transcriptWords,
                        thresholdDB: project.detection.thresholdDB)
                    op = .delete(ranges: cuts.map(\.range))
                    warnings += cuts.filter { !$0.inSilence }.map {
                        "Операция \(index + 1), слова #\($0.words.lowerBound)–\($0.words.upperBound): рядом нет тишины, "
                            + "рез по границе слова. Проверьте склейку montazhka_audio и montazhka_frames."
                    }
                }
                clips = try TimelineEditOps.apply([op], to: clips, sourceDurations: durations)
            }
            warnings += Self.fragmentWarnings(clips, previousIDs: previousIDs)
            try await revisions.push(project)
            project.clips = clips
            project.updatedAt = Date()
            do {
                try await store.save(project)
            } catch {
                await revisions.drop(projectID: projectID, steps: 1)
                throw error
            }
            if transcriptWords == nil {
                warnings.append("Расшифровки нет в кэше — резы посреди слов не проверялись.")
            }
            return try await editResponse(project, warnings: warnings)
        } catch { return failure("apply_edits", error) }
    }

    /// `deleteWords` → резы по ленте. Номера слов верны только для той ленты,
    /// по которой агент читал расшифровку, — это проверяет отпечаток `timeline`.
    private func wordCuts(
        _ operation: AgentEditOperation, clips: [Clip], transcript: [TranscriptWord]?, thresholdDB: Double
    ) async throws -> [AgentWordCut] {
        guard let transcript else {
            throw AgentServiceError.invalidInput(
                "Для deleteWords нужна расшифровка: вызовите montazhka_transcript и дождитесь её.")
        }
        guard let ranges = operation.words, !ranges.isEmpty else {
            throw AgentServiceError.invalidInput("Операции deleteWords нужно поле words: [{from, to}].")
        }
        guard let timeline = operation.timeline else {
            throw AgentServiceError.invalidInput(
                "Операции deleteWords нужно поле timeline из ответа montazhka_transcript.")
        }
        guard timeline == AgentWordCuts.fingerprint(clips) else {
            throw AgentServiceError.invalidInput(
                "Лента изменилась после чтения расшифровки, номера слов устарели. Вызовите montazhka_transcript "
                    + "заново и возьмите новые номера и timeline. Несколько диапазонов — в одном deleteWords.")
        }
        for path in Set(clips.map(\.sourcePath)) { _ = await waveforms.ensure(path: path) }
        let map = TranscriptTimelineMapper.make(clips: clips, transcripts: transcript)
        return try AgentWordCuts.timelineRanges(
            ranges, map: map, clips: clips, peaksFor: { self.waveforms.peaks(for: $0) },
            thresholdDB: thresholdDB)
    }

    /// `fixWords`: слова #from…#to становятся одним словом `text` (остальные
    /// скрываются). Исправление хранится у исходника, а не в проекте, поэтому
    /// видно во всех его проектах и не откатывается `undo` — только новым fixWords.
    private func fixWords(_ operation: AgentEditOperation, clips: [Clip]) async throws {
        guard let range = operation.words?.first, operation.words?.count == 1, range.from <= range.to else {
            throw AgentServiceError.invalidInput("fixWords: нужен один диапазон words: [{from, to}].")
        }
        guard let text = operation.text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            throw AgentServiceError.invalidInput("fixWords: нужно поле text — правильное написание.")
        }
        guard operation.timeline == AgentWordCuts.fingerprint(clips) else {
            throw AgentServiceError.invalidInput(
                "fixWords: лента изменилась после чтения расшифровки. Вызовите montazhka_transcript заново.")
        }
        let project = Project(name: "", clips: clips)
        guard let words = try await cachedTranscriptWords(for: project) else {
            throw AgentServiceError.invalidInput("Для fixWords нужна расшифровка: вызовите montazhka_transcript.")
        }
        let mapped = TranscriptTimelineMapper.make(clips: clips, transcripts: words).words
        guard range.from >= 1, range.to <= mapped.count else {
            throw AgentServiceError.invalidInput("fixWords: в расшифровке только \(mapped.count) слов.")
        }
        let chosen = Array(mapped[(range.from - 1)...(range.to - 1)])
        guard let sourceID = chosen.first?.sourceID, chosen.allSatisfy({ $0.sourceID == sourceID }),
            let source = clips.first(where: { $0.source.id == sourceID })?.source
        else { throw AgentServiceError.invalidInput("fixWords: слова должны быть из одного исходника.") }

        let transcriptStore = makeTranscriptStore()
        let raw = try await transcriptStore.ensure(source: source)
        let fixesURL = TranscriptCorrections.url(forTranscript: await transcriptStore.cacheURL(for: source))
        var fixes = TranscriptCorrections.load(from: fixesURL)
        let indices = chosen.compactMap { word in raw.firstIndex { abs($0.start - word.sourceStart) < 0.0005 } }
        guard indices.count == chosen.count else {
            throw AgentServiceError.invalidInput("fixWords: не удалось сопоставить слова с расшифровкой.")
        }
        for (offset, index) in indices.enumerated() { fixes[index] = offset == 0 ? text : "" }
        try TranscriptCorrections.save(fixes, to: fixesURL)

        if operation.remember == true {
            var glossary = Glossary.load(from: store.glossaryURL)
            glossary.remember(original: indices.map { raw[$0].text }, replacement: text)
            try glossary.save(to: store.glossaryURL)
        }
    }

    /// Лента проекта для агента: номера клипов, их место на ленте и в исходнике.
    func clipsData(_ project: Project, offset: Int = 0, limit: Int = 200) -> AgentJSONValue {
        let starts = TimelineEditOps.starts(of: project.clips)
        return .array(
            Array(zip(project.clips, starts).enumerated()).dropFirst(offset).prefix(limit).map { index, pair in
                let (clip, start) = pair
                return .object([
                    "clip": .number(Double(index)),
                    "timelineStart": .number(Self.rounded(start)),
                    "timelineEnd": .number(Self.rounded(start + clip.duration)),
                    "sourcePath": .string(clip.sourcePath),
                    "sourceStart": .number(Self.rounded(clip.start)),
                    "sourceEnd": .number(Self.rounded(clip.end)),
                ])
            })
    }

    private func editResponse(_ project: Project, warnings: [String]) async throws -> AgentResponse {
        let shown = min(Self.editResponseClips, project.clips.count)
        var data: [String: AgentJSONValue] = [
            "projectId": .string(project.id.uuidString),
            "revision": .number(Double(await revisions.revision(of: project.id))),
            "duration": .number(Self.rounded(project.totalDuration)),
            "clipCount": .number(Double(project.clips.count)),
            "clipsShown": .number(Double(shown)),
            "clips": clipsData(project, limit: shown),
            "warnings": .array(warnings.map { .string($0) }),
        ]
        if shown < project.clips.count {
            data["more"] = .string("Показаны первые \(shown) клипов. Остальные — montazhka_inspect с offset=\(shown).")
        }
        return .success(command: "apply_edits", data: data)
    }

    private static let editResponseClips = 50
    /// Короче этого новый кусок почти наверняка обрывок слова или щелчок.
    private static let fragmentThreshold = 0.25

    /// Предупреждает о коротких кусках, которые появились в этой правке.
    /// Сам движок их не удаляет: короткое «да» — тоже законный клип.
    static func fragmentWarnings(_ clips: [Clip], previousIDs: Set<UUID>) -> [String] {
        clips.enumerated().compactMap { index, clip in
            guard !previousIDs.contains(clip.id), clip.duration < fragmentThreshold else { return nil }
            return "Клип \(index) длится \(String(format: "%.2f", clip.duration)) с — похоже на обрывок. "
                + "Проверьте его в montazhka_transcript и удалите, если он лишний."
        }
    }

    /// Предупреждает, если точка реза на ленте попадает внутрь слова.
    private static func wordSplitWarnings(
        _ op: TimelineEditOp, index: Int, clips: [Clip], sourceWords: [UUID: [MappedTranscriptWord]]
    ) -> [String] {
        let points: [Double]
        switch op {
        case .delete(let ranges): points = ranges.flatMap { [$0.from, $0.to] }
        case .split(let at), .insert(_, _, _, let at): points = [at]
        default: return []
        }
        let starts = TimelineEditOps.starts(of: clips)
        return points.compactMap { point in
            guard
                let clipIndex = clips.indices.first(where: {
                    point > starts[$0] && point < starts[$0] + clips[$0].duration
                })
            else { return nil }
            let clip = clips[clipIndex]
            let sourceTime = clip.start + point - starts[clipIndex]
            guard
                let word = sourceWords[clip.source.id]?.first(where: {
                    sourceTime > $0.sourceStart + 0.03 && sourceTime < $0.sourceEnd - 0.03
                })
            else { return nil }
            return "Операция \(index + 1): точка \(String(format: "%.2f", point)) режет слово «\(word.text)»."
        }
    }
}
