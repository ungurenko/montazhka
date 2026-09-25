@preconcurrency import AVFoundation
import Foundation

/// Что агент рассматривает: ленту проекта (время ролика) или готовый файл (время файла).
struct AgentMediaTarget: Sendable {
    var projectID: UUID?
    var filePath: String?
}

/// Запрос сетки кадров: либо равномерно `count` кадров в `from…to`, либо точные `times`,
/// либо пары «до/после» каждой склейки (`aroundCuts`).
struct AgentFramesRequest: Sendable {
    var target: AgentMediaTarget
    var from: Double?
    var to: Double?
    var count: Int?
    var times: [Double] = []
    var aroundCuts = false
}

extension AgentService {
    static let transcriptPageWords = 1500

    // MARK: - Кадры

    func frames(_ request: AgentFramesRequest) async -> AgentResponse {
        do {
            var project: Project?
            var shortsDraft: ShortsRenderer.Plan?
            if let id = request.target.projectID { project = try await store.load(id: id) }
            let asset: AVAsset
            let duration: Double
            if let path = request.target.filePath {
                let url = URL(fileURLWithPath: path).standardized
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw AgentServiceError.missingFile(url.path)
                }
                asset = AVURLAsset(url: url)
                duration = try await asset.load(.duration).seconds
            } else if let project, project.shorts != nil {
                guard !project.clips.isEmpty else { throw AgentServiceError.emptyProject }
                // Черновик шортса агент видит таким, каким он выйдет: вертикально,
                // с лицом в кадре, наездами, хуком и субтитрами.
                let plan = try await shortsPlan(project, quality: .compact)
                shortsDraft = plan
                asset = plan.composition
                duration = project.totalDuration
            } else if let project {
                guard !project.clips.isEmpty else { throw AgentServiceError.emptyProject }
                asset = await CompositionBuilder.buildResult(clips: project.clips).composition
                duration = project.totalDuration
            } else {
                throw AgentServiceError.invalidInput("Нужен projectId или filePath.")
            }

            let from = min(max(0, request.from ?? 0), duration)
            let to = min(max(from, request.to ?? duration), duration)
            var times: [Double]
            var labels: [String]?
            if request.aroundCuts {
                guard let project else {
                    throw AgentServiceError.invalidInput("Для aroundCuts нужен projectId: склейки берутся из проекта.")
                }
                let cuts = TimelineEditOps.starts(of: project.clips).dropFirst().filter { $0 >= from && $0 <= to }
                guard !cuts.isEmpty else {
                    throw AgentServiceError.invalidInput("В этом диапазоне нет склеек.")
                }
                let shown = Array(cuts.prefix(FrameSheetRenderer.maxFrames / 2))
                times = shown.flatMap { [max(0, $0 - 0.08), min(duration - 0.01, $0 + 0.04)] }
                labels = shown.flatMap { cut in
                    let code = FrameSheetRenderer.timecode(cut)
                    return ["\(code) до", "\(code) после"]
                }
            } else if !request.times.isEmpty {
                times = request.times.map { min(max(0, $0), max(0, duration - 0.01)) }
            } else {
                guard to > from else {
                    throw AgentServiceError.invalidInput("Диапазон кадров пуст: to должно быть больше from.")
                }
                times = FrameSheetRenderer.evenTimes(from: from, to: to, count: request.count ?? 8)
            }
            times = Array(times.prefix(FrameSheetRenderer.maxFrames))

            let directory = inspectionsDirectory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            Self.removeOldInspections(in: directory)
            let url = directory.appendingPathComponent("frames-\(UUID().uuidString).jpg")
            let sheet = try await FrameSheetRenderer.render(
                asset: asset, videoComposition: shortsDraft?.frameComposition, times: times, labels: labels,
                to: url, overlayAt: shortsDraft.map { plan in { plan.overlay(at: $0) } })
            return .success(
                command: "frames",
                data: [
                    "imagePath": .string(url.path),
                    "times": .array(times.map { .number(Self.rounded($0)) }),
                    "extracted": .number(Double(sheet.extracted)),
                    "width": .number(Double(sheet.width)), "height": .number(Double(sheet.height)),
                    "duration": .number(Self.rounded(duration)),
                ])
        } catch { return failure("frames", error) }
    }

    // MARK: - Громкость

    func audio(target: AgentMediaTarget, from: Double?, to: Double?, buckets: Int?) async -> AgentResponse {
        do {
            let clips: [Clip]
            var settings = DetectionSettings(minPauseDuration: 0.4, paddingMS: 0)
            if let path = target.filePath {
                let url = URL(fileURLWithPath: path).standardized
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw AgentServiceError.missingFile(url.path)
                }
                let duration = try await AVURLAsset(url: url).load(.duration).seconds
                clips = [Clip(sourcePath: url.path, start: 0, end: duration)]
            } else if let id = target.projectID {
                let project = try await store.load(id: id)
                clips = project.clips
                settings.thresholdDB = project.detection.thresholdDB
            } else {
                throw AgentServiceError.invalidInput("Нужен projectId или filePath.")
            }
            guard !clips.isEmpty else { throw AgentServiceError.emptyProject }
            for path in Set(clips.map(\.sourcePath)) { await waveforms.ensure(path: path) }
            let total = clips.reduce(0) { $0 + $1.duration }
            let report = LoudnessProbe.measure(
                clips: clips, peaksFor: { self.waveforms.peaks(for: $0) },
                from: from ?? 0, to: to ?? total, buckets: buckets ?? 60, settings: settings)
            return .success(
                command: "audio",
                data: [
                    "from": .number(Self.rounded(report.from)), "to": .number(Self.rounded(report.to)),
                    "bucketSeconds": .number(Self.rounded(report.bucketSeconds)),
                    "levelsDB": .array(report.levelsDB.map { .number($0) }),
                    "loudestDB": .number(report.loudestDB),
                    "silenceThresholdDB": .number(settings.thresholdDB),
                    "silences": .array(
                        report.silences.map {
                            .object(["from": .number(Self.rounded($0.from)), "to": .number(Self.rounded($0.to))])
                        }),
                ])
        } catch { return failure("audio", error) }
    }

    // MARK: - Расшифровка

    /// Слова исходников проекта (время исходника). Если какой-то исходник ещё
    /// не расшифрован, возвращает nil — расшифровку нужно запустить фоновой задачей.
    func cachedTranscriptWords(for project: Project) async throws -> [TranscriptWord]? {
        try await makeTranscriptStore().correctedCachedWords(
            for: uniqueSources(project.clips), glossaryURL: store.glossaryURL)
    }

    /// Слова во времени ленты.
    func cachedTimelineTranscript(for project: Project) async throws -> TranscriptTimelineMap? {
        try await cachedTranscriptWords(for: project).map {
            TranscriptTimelineMapper.make(clips: project.clips, transcripts: $0)
        }
    }

    func transcript(projectID: UUID, from: Double?, to: Double?, query: String? = nil) async -> AgentResponse {
        do {
            let project = try await store.load(id: projectID)
            guard let map = try await cachedTimelineTranscript(for: project) else {
                return .failure(
                    command: "transcript", code: "TRANSCRIPT_NOT_READY",
                    message: "Расшифровка этого проекта ещё не готова.",
                    recovery: "montazhka_transcript сам запускает её в фоне; дождитесь задачи в montazhka_get_job.")
            }
            let timeline = AgentWordCuts.fingerprint(project.clips)
            if let query, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                return transcriptSearch(query, map: map, projectID: project.id, timeline: timeline)
            }
            let lower = from ?? 0
            let upper = to ?? project.totalDuration
            let inRange = map.words.enumerated().filter {
                $0.element.timelineEnd > lower && $0.element.timelineStart < upper
            }
            let page = inRange.prefix(Self.transcriptPageWords)
            var peaksBySource: [UUID: [Float]] = [:]
            for clip in project.clips where peaksBySource[clip.source.id] == nil {
                peaksBySource[clip.source.id] = await waveforms.ensure(path: clip.sourcePath)
            }
            var lines: [String] = []
            var previous: MappedTranscriptWord?
            for (number, word) in page {
                if let previous {
                    if previous.clipID != word.clipID {
                        lines.append("--- склейка \(Self.format(word.timelineStart)) ---")
                    }
                    let gap = word.timelineStart - previous.timelineEnd
                    let hum =
                        previous.clipID == word.clipID
                        ? peaksBySource[word.sourceID].flatMap {
                            FillerDetector.voicedSpan(
                                from: previous.sourceEnd, to: word.sourceStart, peaks: $0,
                                thresholdDB: project.detection.thresholdDB)
                        } : nil
                    if let hum {
                        // Звук без слов: скорее всего «эээ». Время — на ленте.
                        let shift = word.timelineStart - word.sourceStart
                        lines.append(
                            "--- звук без слов \(Self.format(hum.lowerBound + shift))–\(Self.format(hum.upperBound + shift)) ---")
                    } else if gap >= 0.4 {
                        lines.append("--- пауза \(String(format: "%.1f", gap)) с ---")
                    }
                }
                // Пустое слово — хвост исправленного термина («клод код» → «Claude Code»).
                let text = word.text.isEmpty ? "·" : word.text
                lines.append(
                    "#\(number + 1) \(Self.format(word.timelineStart)) \(Self.format(word.timelineEnd)) \(text)")
                previous = word
            }
            let next = inRange.count > page.count ? inRange[page.count].element.timelineStart : nil
            return .success(
                command: "transcript",
                data: [
                    "projectId": .string(project.id.uuidString),
                    "format": "#номер начало конец слово (секунды ленты)",
                    "timeline": .string(timeline),
                    "wordCount": .number(Double(page.count)),
                    "text": .string(lines.joined(separator: "\n")),
                    "nextFrom": next.map { .number(Self.rounded($0)) } ?? .null,
                ])
        } catch { return failure("transcript", error) }
    }

    static let searchMatchLimit = 30
    private static let searchContextWords = 6

    /// Где в ролике звучит фраза: номера слов для deleteWords, время ленты и контекст.
    private func transcriptSearch(
        _ query: String, map: TranscriptTimelineMap, projectID: UUID, timeline: String
    ) -> AgentResponse {
        let words = map.words
        let found = TranscriptSearch.matches(of: query, in: words.map(\.text))
        let matches = found.prefix(Self.searchMatchLimit).map { range -> AgentJSONValue in
            let before = words[max(0, range.lowerBound - Self.searchContextWords)..<range.lowerBound].map(\.text)
            let after = words[(range.upperBound + 1)..<min(words.count, range.upperBound + 1 + Self.searchContextWords)]
                .map(\.text)
            let hit = words[range].map(\.text).joined(separator: " ")
            return .object([
                "from": .number(Double(range.lowerBound + 1)), "to": .number(Double(range.upperBound + 1)),
                "start": .number(Self.rounded(words[range.lowerBound].timelineStart)),
                "end": .number(Self.rounded(words[range.upperBound].timelineEnd)),
                "text": .string((before + ["[\(hit)]"] + after).joined(separator: " ")),
            ])
        }
        return .success(
            command: "transcript",
            data: [
                "projectId": .string(projectID.uuidString), "query": .string(query),
                "timeline": .string(timeline), "matchCount": .number(Double(found.count)),
                "matches": .array(Array(matches)),
            ])
    }

    /// Точка входа инструмента: готовая расшифровка сразу, иначе фоновая задача.
    /// Расшифровка длинного ролика идёт минутами — дольше, чем живёт один вызов.
    func transcriptOrStartJob(
        projectID: UUID, from: Double?, to: Double?, query: String? = nil, confirmModelDownload: Bool
    ) async -> AgentResponse {
        let response = await transcript(projectID: projectID, from: from, to: to, query: query)
        guard response.error?.code == "TRANSCRIPT_NOT_READY" else { return response }
        if let refusal = await refusalIfModelNeedsDownload(command: "transcript", confirmed: confirmModelDownload) {
            return refusal
        }
        do {
            let started = try await AgentBackgroundJob.submit(.transcribe(projectID: projectID))
            var data = started.data ?? [:]
            data["next"] = "Дождитесь status=completed в montazhka_get_job и вызовите montazhka_transcript снова."
            return .success(command: "transcript", data: data)
        } catch {
            return .failure(command: "transcript", code: "JOB_START_FAILED", message: error.localizedDescription)
        }
    }

    /// Фоновая часть: расшифровать все исходники проекта и сохранить в кэш.
    func transcribe(projectID: UUID, runMode: AgentRunMode) async -> AgentResponse {
        var activeRunID: UUID?
        do {
            let project = try await store.load(id: projectID)
            let run = try await beginRun(
                mode: runMode, kind: .transcribe, sourcePaths: project.clips.map(\.sourcePath),
                stage: "Расшифровка", projectID: projectID)
            activeRunID = run.id
            let transcriptStore = makeTranscriptStore()
            let sources = uniqueSources(project.clips)
            for (index, source) in sources.enumerated() {
                _ = try await transcriptStore.ensure(source: source) { _ in
                    try? await self.runs.update(id: run.id) {
                        $0.stage = "Расшифровка \(index + 1) из \(sources.count)"
                        $0.progress = Double(index) / Double(max(1, sources.count))
                    }
                }
            }
            try await runs.update(id: run.id) {
                $0.status = .completed; $0.progress = 1; $0.stage = "Расшифровка готова"
                $0.summary = "Вызовите montazhka_transcript ещё раз."
            }
            return .success(
                command: "transcribe",
                data: ["jobId": .string(run.id.uuidString), "status": .string("completed")])
        } catch {
            if let activeRunID { await failRun(id: activeRunID, error: error) }
            return failure("transcribe", error)
        }
    }

    func uniqueSources(_ clips: [Clip]) -> [MediaReference] {
        var seen = Set<UUID>()
        return clips.compactMap { seen.insert($0.source.id).inserted ? $0.source : nil }
    }

    var inspectionsDirectory: URL {
        runs.baseDirectory.deletingLastPathComponent().appendingPathComponent("AgentInspections", isDirectory: true)
    }

    /// Сетки кадров нужны агенту на время монтажа — старше суток не храним.
    private static func removeOldInspections(in directory: URL) {
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if let modified, modified < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }

    static func rounded(_ value: Double) -> Double {
        (value * 1000).rounded() / 1000
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
