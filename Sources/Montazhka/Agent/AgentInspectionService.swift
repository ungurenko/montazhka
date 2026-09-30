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
    /// Склейки для `aroundCuts` вместо всех склеек проекта в `from…to` (их выбирает `montazhka_check`).
    var cuts: [Double]?
}

/// Запрос `montazhka_transcript`: ровно одно из `target.projectID` (время ленты)
/// и `target.filePath` (любой файл, время файла).
struct AgentTranscriptRequest: Sendable {
    var target: AgentMediaTarget
    var from: Double?
    var to: Double?
    var query: String?
    /// Строки фраз вместо строк слов.
    var phrases = false
    /// Подсказки о дублях по всей расшифровке, а не только по странице.
    var retakes = false
    var confirmModelDownload = false
}

/// Слова, которые показывает transcript, и то, что нужно для их вывода.
private struct TranscriptView {
    let words: [MappedTranscriptWord]
    let clips: [Clip]
    let thresholdDB: Double
    /// Чьи слова: projectId и отпечаток ленты или filePath и `timeBase=file`.
    let identity: [String: AgentJSONValue]
    let timeUnit: String
}

extension AgentService {
    static let transcriptPageWords = 1500

    // MARK: - Кадры

    func frames(_ request: AgentFramesRequest) async -> AgentResponse {
        do {
            var project: Project?
            // Своя картинка ролика: вертикальный черновик шортса или анимации и вшитые субтитры
            // обычного проекта; nil — кадры как есть.
            var videoComposition: AVVideoComposition?
            var overlayAt: ((Double) -> CGImage?)?
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
                asset = plan.composition
                videoComposition = plan.frameComposition
                overlayAt = { plan.overlay(at: $0) }
                duration = project.totalDuration
            } else if let project {
                guard !project.clips.isEmpty else { throw AgentServiceError.emptyProject }
                // Обычный проект — как в готовом MP4: анимации и (если включены) вшитые субтитры.
                let words =
                    project.export.burnSubtitles
                    ? ((try? await cachedTimelineTranscript(for: project)) ?? nil)?.words : nil
                let plan = try await MediaPipeline(
                    voiceStore: VoiceEnhanceStore(cacheDir: store.enhancedAudioDir),
                    musicEQStore: MusicEQStore(cacheDir: store.musicEQDir)
                ).framePlan(for: project, words: words)
                asset = plan.asset
                videoComposition = plan.videoComposition
                overlayAt = plan.overlayAt
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
                let cuts =
                    request.cuts
                    ?? TimelineEditOps.starts(of: project.clips).dropFirst().filter { $0 >= from && $0 <= to }
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
                asset: asset, videoComposition: videoComposition, times: times, labels: labels, to: url,
                overlayAt: overlayAt)
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
            var fileURL: URL?
            if let path = target.filePath {
                let url = URL(fileURLWithPath: path).standardized
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw AgentServiceError.missingFile(url.path)
                }
                let duration = try await AVURLAsset(url: url).load(.duration).seconds
                clips = [Clip(sourcePath: url.path, start: 0, end: duration)]
                fileURL = url
            } else if let id = target.projectID {
                let project = try await store.load(id: id)
                clips = project.clips
                settings.thresholdDB = project.detection.thresholdDB
            } else {
                throw AgentServiceError.invalidInput("Нужен projectId или filePath.")
            }
            guard !clips.isEmpty else { throw AgentServiceError.emptyProject }
            let total = clips.reduce(0) { $0 + $1.duration }
            let range = LoudnessProbe.normalizedRange(total: total, from: from ?? 0, to: to ?? total)
            for path in LoudnessProbe.sourcePaths(clips: clips, range: range) { await waveforms.ensure(path: path) }
            let report = LoudnessProbe.measure(
                clips: clips, peaksFor: { self.waveforms.peaks(for: $0) },
                from: from ?? 0, to: to ?? total, buckets: buckets ?? 60, settings: settings)
            var data: [String: AgentJSONValue] = [
                "from": .number(Self.rounded(report.from)), "to": .number(Self.rounded(report.to)),
                "bucketSeconds": .number(Self.rounded(report.bucketSeconds)),
                "levelsDB": .array(report.levelsDB.map { .number($0) }),
                "loudestDB": .number(report.loudestDB),
                "silenceThresholdDB": .number(settings.thresholdDB),
                "silences": .array(
                    report.silences.map {
                        .object(["from": .number(Self.rounded($0.from)), "to": .number(Self.rounded($0.to))])
                    }),
            ]
            // Громкость всего файла по стандарту площадок (LUFS) — у готового MP4.
            if let fileURL { data["loudness"] = await Self.fileLoudness(fileURL) }
            return .success(command: "audio", data: data)
        } catch { return failure("audio", error) }
    }

    /// Громкость файла целиком: LUFS, истинный пик и разброс; null — в файле нет звука.
    static func fileLoudness(_ url: URL) async -> AgentJSONValue {
        guard let measured = try? await LoudnessMeter.measure(url: url) else { return .null }
        return .object([
            "integratedLUFS": measured.integratedLUFS.map { .number(rounded($0)) } ?? .null,
            "truePeakDBTP": .number(rounded(measured.truePeakDBTP)),
            "loudnessRangeLU": measured.loudnessRangeLU.map { .number(rounded($0)) } ?? .null,
            "targetLUFS": .number(LoudnessTarget().integrated),
        ])
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

    /// Расшифровка из кэша: страница слов или фраз, поиск `query`, дубли `retakes`.
    /// Нет расшифровки — `TRANSCRIPT_NOT_READY` (её запускает `transcriptOrStartJob`).
    func transcript(_ request: AgentTranscriptRequest) async -> AgentResponse {
        guard (request.target.projectID == nil) != (request.target.filePath == nil) else {
            return .failure(
                command: "transcript", code: "INVALID_INPUT",
                message: "Передайте ровно одно: projectId (проект) или filePath (любой файл).")
        }
        do {
            guard let view = try await transcriptView(request.target) else {
                return .failure(
                    command: "transcript", code: "TRANSCRIPT_NOT_READY",
                    message:
                        "Расшифровка этого \(request.target.projectID == nil ? "файла" : "проекта") ещё не готова.",
                    recovery: "montazhka_transcript сам запускает её в фоне; дождитесь задачи в montazhka_get_job.")
            }
            var data = view.identity
            let sources: [MediaReference]
            if let id = request.target.projectID {
                sources = uniqueSources(try await store.load(id: id).clips)
            } else {
                sources = [MediaReference(path: Self.transcriptFilePath(request.target))]
            }
            data["dependencyFingerprint"] = .string(await inputDependencyFingerprint(sources: sources))
            if let query = request.query, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                data.merge(Self.transcriptSearch(query, words: view.words)) { _, new in new }
            } else {
                let page = await transcriptPage(view, from: request.from, to: request.to, phrases: request.phrases)
                data.merge(page) { _, new in new }
            }
            if request.retakes { data["retakes"] = Self.retakesData(view.words) }
            return .success(command: "transcript", data: data)
        } catch { return failure("transcript", error) }
    }

    /// Слова проекта во времени ленты или слова файла во времени файла; nil — расшифровки нет в кэше.
    private func transcriptView(_ target: AgentMediaTarget) async throws -> TranscriptView? {
        if let projectID = target.projectID {
            let project = try await store.load(id: projectID)
            guard let map = try await cachedTimelineTranscript(for: project) else { return nil }
            return TranscriptView(
                words: map.words, clips: project.clips, thresholdDB: project.detection.thresholdDB,
                identity: [
                    "projectId": .string(project.id.uuidString),
                    "timeline": .string(AgentWordCuts.fingerprint(project.clips)),
                ],
                timeUnit: "секунды ленты")
        }
        let path = Self.transcriptFilePath(target)
        guard FileManager.default.fileExists(atPath: path) else { throw AgentServiceError.missingFile(path) }
        let media = MediaReference(path: path)
        guard
            let words = try await makeTranscriptStore().correctedCachedWords(
                for: [media], glossaryURL: store.glossaryURL)
        else { return nil }
        // Один клип на весь файл: время «ленты» совпадает со временем файла, склеек нет.
        let clip = Clip(source: media, start: 0, end: words.map(\.end).max() ?? 0)
        return TranscriptView(
            words: TranscriptTimelineMapper.make(clips: [clip], transcripts: words).words, clips: [clip],
            thresholdDB: DetectionSettings().thresholdDB,
            identity: ["filePath": .string(path), "timeBase": "file"], timeUnit: "секунды файла")
    }

    /// Путь файла для расшифровки. Один и тот же и для чтения, и для фоновой задачи:
    /// кэш расшифровки ищется по пути.
    static func transcriptFilePath(_ target: AgentMediaTarget) -> String {
        URL(fileURLWithPath: target.filePath ?? "").standardized.path
    }

    /// Страница до `transcriptPageWords` слов в `from…to`: строки слов или строки фраз.
    private func transcriptPage(
        _ view: TranscriptView, from: Double?, to: Double?, phrases: Bool
    ) async -> [String: AgentJSONValue] {
        let lower = from ?? 0
        let upper = to ?? .infinity
        let inRange = view.words.enumerated().filter {
            $0.element.timelineEnd > lower && $0.element.timelineStart < upper
        }
        let page = Array(inRange.prefix(Self.transcriptPageWords))
        let lines = phrases ? Self.phraseLines(page, words: view.words) : await wordLines(page, view: view)
        let next = inRange.count > page.count ? inRange[page.count].element.timelineStart : nil
        return [
            "format": .string(
                phrases
                    ? "¶фраза #первое–#последнее начало конец текст (\(view.timeUnit))"
                    : "#номер начало конец слово (\(view.timeUnit))"),
            "wordCount": .number(Double(page.count)),
            "text": .string(lines.joined(separator: "\n")),
            "nextFrom": next.map { .number(Self.rounded($0)) } ?? .null,
        ]
    }

    /// Строки `#номер начало конец слово` с отметками склеек, пауз и звука без слов.
    private func wordLines(
        _ page: [(offset: Int, element: MappedTranscriptWord)], view: TranscriptView
    ) async -> [String] {
        var peaksBySource: [UUID: [Float]] = [:]
        let needed = Set(page.map { $0.element.sourceID })
        var idsByPath: [String: Set<UUID>] = [:]
        for clip in view.clips where needed.contains(clip.source.id) {
            idsByPath[clip.sourcePath, default: []].insert(clip.source.id)
        }
        for (path, ids) in idsByPath {
            let peaks = await waveforms.ensure(path: path)
            for id in ids { peaksBySource[id] = peaks }
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
                            thresholdDB: view.thresholdDB)
                    } : nil
                if let hum {
                    // Звук без слов: скорее всего «эээ». Время — на ленте.
                    let shift = word.timelineStart - word.sourceStart
                    lines.append(
                        "--- звук без слов \(Self.format(hum.lowerBound + shift))–\(Self.format(hum.upperBound + shift)) ---"
                    )
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
        return lines
    }

    /// Фразы, задетые страницей, целиком: `¶номер #первое–#последнее начало конец текст`.
    /// Номера с 1, как у слов: `#первое`–`#последнее` сразу годятся для deleteWords.
    private static func phraseLines(
        _ page: [(offset: Int, element: MappedTranscriptWord)], words: [MappedTranscriptWord]
    ) -> [String] {
        guard let first = page.first?.offset, let last = page.last?.offset else { return [] }
        return RetakeFinder.phrases(words).filter { $0.lastWord >= first && $0.firstWord <= last }.map {
            "¶\($0.index + 1) #\($0.firstWord + 1)–#\($0.lastWord + 1) \(format($0.start)) \(format($0.end)) \($0.text)"
        }
    }

    /// Вероятные дубли по всей расшифровке. `RetakeFinder` считает с 0, агент — с 1:
    /// `from`/`to` дубля — номера слов для deleteWords, `phrase` — номер строки `¶`.
    static func retakesData(_ words: [MappedTranscriptWord]) -> AgentJSONValue {
        let phrases = RetakeFinder.phrases(words)
        return .array(
            RetakeFinder.retakes(phrases, words: words).map { group in
                .object([
                    "kind": .string(group.kind.rawValue),
                    "similarity": .number((group.similarity * 100).rounded() / 100),
                    "takes": .array(
                        group.phrases.map { index in
                            let phrase = phrases[index]
                            return .object([
                                "phrase": .number(Double(phrase.index + 1)),
                                "from": .number(Double(phrase.firstWord + 1)),
                                "to": .number(Double(phrase.lastWord + 1)),
                                "start": .number(rounded(phrase.start)), "end": .number(rounded(phrase.end)),
                                "text": .string(phrase.text),
                            ])
                        }),
                ])
            })
    }

    static let searchMatchLimit = 30
    private static let searchContextWords = 6

    /// Где звучит фраза: номера слов для deleteWords, время и контекст.
    private static func transcriptSearch(_ query: String, words: [MappedTranscriptWord]) -> [String: AgentJSONValue] {
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
        return [
            "query": .string(query), "matchCount": .number(Double(found.count)),
            "matches": .array(Array(matches)),
        ]
    }

    /// Точка входа инструмента: готовая расшифровка сразу, иначе фоновая задача.
    /// Расшифровка длинного ролика идёт минутами — дольше, чем живёт один вызов.
    func transcriptOrStartJob(_ request: AgentTranscriptRequest) async -> AgentResponse {
        let response = await transcript(request)
        guard response.error?.code == "TRANSCRIPT_NOT_READY" else { return response }
        if let refusal = await refusalIfModelNeedsDownload(
            command: "transcript", confirmed: request.confirmModelDownload)
        {
            return refusal
        }
        let job: AgentWorkerRequest =
            request.target.projectID.map { .transcribe(projectID: $0) }
            ?? .transcribeFile(path: Self.transcriptFilePath(request.target))
        do {
            let started = try await startJob(job)
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

    /// Фоновая часть расшифровки любого файла (не проекта): распознать и сохранить в кэш.
    func transcribeFile(path: String, runMode: AgentRunMode) async -> AgentResponse {
        var activeRunID: UUID?
        do {
            let run = try await beginRun(mode: runMode, kind: .transcribe, sourcePaths: [path], stage: "Расшифровка")
            activeRunID = run.id
            guard FileManager.default.fileExists(atPath: path) else { throw AgentServiceError.missingFile(path) }
            let source = MediaReference(path: path)
            let transcriptStore = makeTranscriptStore()
            _ = try await transcriptStore.ensure(source: source)
            // Словарь терминов и ручные исправления — так же, как у расшифровки проекта.
            let words =
                try await transcriptStore.correctedCachedWords(for: [source], glossaryURL: store.glossaryURL) ?? []
            try await runs.update(id: run.id) {
                $0.status = .completed; $0.progress = 1; $0.stage = "Расшифровка готова"
                $0.summary = "Слов: \(words.count). Вызовите montazhka_transcript с filePath ещё раз."
            }
            return .success(
                command: "transcribe",
                data: [
                    "jobId": .string(run.id.uuidString), "status": .string("completed"),
                    "wordCount": .number(Double(words.count)),
                ])
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
