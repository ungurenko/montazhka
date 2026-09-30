@preconcurrency import AVFoundation
import Foundation

/// Запрос `montazhka_check`: готовый файл проекта и какие склейки в нём проверить.
struct AgentCheckRequest: Sendable {
    var projectID: UUID
    /// nil — MP4 черновика шортса (`shorts.exportPath`); у обычного проекта путь обязателен.
    var filePath: String?
    var from: Double?
    var to: Double?
    /// Секунды файла по каждую сторону склейки; nil — `SeamProbe.window`.
    var window: Double?
    /// Сверять слова ленты со словами файла (нужна расшифровка файла).
    var words = true
    var confirmModelDownload = false
    /// Полную громкость достаточно измерить на первой странице отчёта.
    var includeLoudness = true
}

/// Дефект у склейки. Порядок случаев — порядок важности в ответе.
private struct CheckProblem: Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case cutWord, click, dropout, black, levelJump
    }

    let time: Double
    let kind: Kind
    let evidence: String

    var priority: Int { Kind.allCases.firstIndex(of: kind) ?? Kind.allCases.count }
}

/// Слова для сверки: слова ленты (время ленты = время файла; nil — расшифровки проекта нет)
/// и слова файла (`heard == nil` — сверки нет, причина в `status`).
private struct CheckWords: Sendable {
    var expected: [SeamWord]?
    var heard: [SeamWord]?
    let status: AgentJSONValue
}

/// Склейка: момент на ленте и клипы по обе стороны — по ним находится тот же момент исходника.
private struct CheckCut: Sendable {
    let time: Double
    let before: Clip
    let after: Clip
}

/// Что нужно каждой склейке, собранное один раз.
private struct CheckContext: Sendable {
    let media: CheckMedia
    let file: AVAsset
    let window: Double
    let words: CheckWords
    /// В проекте играет музыка: без расшифровки её в паузах не отличить от речи.
    let music: Bool
    /// Склейка проекта без улучшения голоса и музыки: с ней сравнивается звук пропавшего слова.
    /// nil — сверки слов нет.
    let source: AVAsset?
    /// Только исходники текущей страницы; освобождаются вместе с её контекстом.
    var sourceAssets: [URL: AVURLAsset]
}

/// Что есть в файле: без звука или без картинки соответствующая проверка — null.
private struct CheckMedia: Sendable {
    let url: URL
    let seconds: Double
    let hasAudio: Bool
    let hasVideo: Bool
}

/// `montazhka_check`: проверка готового MP4 у каждой склейки проекта — щелчок, провал звука,
/// скачок громкости, чёрный кадр, пропавшее у склейки слово. Только чтение.
extension AgentService {
    static let checkCutLimit = 40
    static let checkImageCuts = 8
    /// Скачок громкости речи у склейки меньше этого — обычная разница фраз, не проблема.
    static let checkLevelJumpDB = 10.0
    /// Пропавшее у склейки слово — дефект, только если в файле это место тише, чем в проекте,
    /// хотя бы на столько: иначе слово звучит, а распознавание его просто не расслышало.
    static let checkWordLostDB = 6.0
    /// Файл без отпечатка проекта считается этим проектом, если длительности сходятся.
    static let checkDurationTolerance = 0.25
    static let fileMismatchMessage = "Файл собран из другой версии проекта — экспортируйте заново"

    func check(_ request: AgentCheckRequest) async -> AgentResponse {
        do {
            let project = try await store.load(id: request.projectID)
            guard let requested = request.filePath ?? project.shorts?.exportPath else {
                return .failure(
                    command: "check", code: "INVALID_INPUT", message: "Нужен filePath — путь к готовому MP4.",
                    recovery: "Передайте path из итога montazhka_export.")
            }
            let path = Self.transcriptFilePath(AgentMediaTarget(filePath: requested))
            guard FileManager.default.fileExists(atPath: path) else { throw AgentServiceError.missingFile(path) }
            let asset = AVURLAsset(url: URL(fileURLWithPath: path))
            let media = CheckMedia(
                url: URL(fileURLWithPath: path), seconds: try await asset.load(.duration).seconds,
                hasAudio: !(try await asset.loadTracks(withMediaType: .audio)).isEmpty,
                hasVideo: !(try await asset.loadTracks(withMediaType: .video)).isEmpty)
            guard let match = await Self.fileMatch(media, project: project) else {
                return .failure(
                    command: "check", code: "FILE_PROJECT_MISMATCH", message: Self.fileMismatchMessage,
                    recovery: "montazhka_export этого проекта с overwrite=true, затем montazhka_check снова.")
            }
            let window = min(5, max(0.5, request.window ?? SeamProbe.window))
            // Округлённый nextFrom может оказаться чуть позже своей склейки — допуск полмиллисекунды.
            let lower = (request.from ?? 0) - 0.0005
            let upper = request.to ?? .infinity
            let starts = TimelineEditOps.starts(of: project.clips)
            let allCuts = project.clips.indices.dropFirst().compactMap { index -> CheckCut? in
                guard starts[index] >= lower, starts[index] <= upper else { return nil }
                return CheckCut(time: starts[index], before: project.clips[index - 1], after: project.clips[index])
            }
            let cuts = Array(allCuts.prefix(Self.checkCutLimit))
            let words = await checkWords(request, project: project, path: path)
            let source: AVAsset? =
                words.heard != nil && media.hasAudio
                ? await CompositionBuilder.buildResult(clips: project.clips).composition : nil
            var context = CheckContext(
                media: media, file: asset, window: window, words: words, music: project.music.enabled, source: source,
                sourceAssets: Dictionary(
                    uniqueKeysWithValues: Set(cuts.flatMap { [$0.before.url, $0.after.url] }).map {
                        ($0, $0 == media.url ? asset : AVURLAsset(url: $0))
                    }))

            var results: [AgentJSONValue] = []
            var problems: [CheckProblem] = []
            for cut in cuts {
                let (result, found) = try await Self.checkCut(cut, context: context)
                results.append(result)
                problems += found
            }
            // Исходники больше не нужны: освобождаем их до громкости и полноразмерных миниатюр.
            context.sourceAssets.removeAll()
            problems.sort { ($0.priority, $0.time) < ($1.priority, $1.time) }
            return .success(
                command: "check",
                data: [
                    "projectId": .string(project.id.uuidString), "filePath": .string(path), "match": .string(match),
                    "fileSeconds": .number(Self.rounded(media.seconds)),
                    "projectSeconds": .number(Self.rounded(project.totalDuration)),
                    "window": .number(window), "cutCount": .number(Double(allCuts.count)),
                    "cuts": .array(results),
                    "problems": .array(
                        problems.map {
                            .object([
                                "time": .number(Self.rounded($0.time)), "kind": .string($0.kind.rawValue),
                                "evidence": .string($0.evidence),
                            ])
                        }),
                    "loudness": media.hasAudio && request.includeLoudness ? await Self.fileLoudness(media.url) : .null,
                    "wordsCheck": words.status,
                    "imagePath": await cutsSheet(cuts.map(\.time), problems: problems, project: project, media: media),
                    "nextFrom": allCuts.count > cuts.count ? .number(Self.rounded(allCuts[cuts.count].time)) : .null,
                ])
        } catch { return failure("check", error) }
    }

    /// "confirmed" — в файле отпечаток этой версии проекта; "unconfirmed" — отпечатка нет, но длительность
    /// сходится; nil — файл собран из другой версии (лента, анимации, музыка, субтитры…).
    private static func fileMatch(_ media: CheckMedia, project: Project) async -> String? {
        guard abs(media.seconds - project.totalDuration) <= checkDurationTolerance else { return nil }
        if let stamp = await ExportProvenance.read(url: media.url) {
            return stamp == ExportProvenance.fingerprint(for: project) ? "confirmed" : nil
        }
        return abs(media.seconds - project.totalDuration) <= checkDurationTolerance ? "unconfirmed" : nil
    }

    /// Слова ленты и файла из кэша расшифровок. Нет расшифровки файла — запускает её в фоне
    /// (модель без согласия не качает: тогда сверка выключена и сказано почему).
    /// Слова ленты нужны и без сверки: по ним сравнивается громкость речи у склейки.
    private func checkWords(_ request: AgentCheckRequest, project: Project, path: String) async -> CheckWords {
        let map = try? await cachedTimelineTranscript(for: project)
        let timeline = map?.words.map { SeamWord(text: $0.text, start: $0.timelineStart, end: $0.timelineEnd) }
        func off(_ reason: String) -> CheckWords {
            CheckWords(expected: timeline, status: .object(["status": "off", "reason": .string(reason)]))
        }
        guard request.words else { return off("Сверка слов выключена (words=false).") }
        guard let expected = timeline else {
            return off("Нет расшифровки проекта: вызовите montazhka_transcript projectId и дождитесь её.")
        }
        if let heard = try? await makeTranscriptStore().correctedCachedWords(
            for: [MediaReference(path: path)], glossaryURL: store.glossaryURL)
        {
            return CheckWords(
                expected: expected, heard: heard.map { SeamWord(text: $0.text, start: $0.start, end: $0.end) },
                status: .object(["status": "done"]))
        }
        if let refusal = await refusalIfModelNeedsDownload(
            command: "check", confirmed: request.confirmModelDownload)
        {
            return off([refusal.error?.message, refusal.error?.recovery].compactMap { $0 }.joined(separator: " "))
        }
        do {
            let started = try await startJob(.transcribeFile(path: path))
            return CheckWords(
                expected: expected,
                status: .object([
                    "status": "pending", "jobId": started.data?["jobId"] ?? .null,
                    "next": "Дождитесь задачи в montazhka_get_job и вызовите montazhka_check снова — сверятся слова.",
                ]))
        } catch {
            return off("Расшифровка файла не запустилась: \(error.localizedDescription)")
        }
    }

    /// Одна склейка: звук окна ±`window` файла, яркость кадра до и после, слова рядом.
    private static func checkCut(
        _ cut: CheckCut, context: CheckContext
    ) async throws -> (AgentJSONValue, [CheckProblem]) {
        var problems: [CheckProblem] = []
        var data: [String: AgentJSONValue] = ["time": .number(rounded(cut.time)), "audio": .null, "video": .null]
        let start = max(0, cut.time - context.window)
        let end = min(context.media.seconds, cut.time + context.window)
        var samples: [Float]?
        if context.media.hasAudio {
            let read = try await SeamProbe.samples(url: context.media.url, from: start, to: end).samples
            samples = read
            data["audio"] = audioFinding(read, cut: cut.time, start: start, context: context, problems: &problems)
        }
        if context.media.hasVideo {
            data["video"] = try await videoFinding(cut, context: context, problems: &problems)
        }
        data["words"] = await wordsFinding(
            cut.time, span: start..<end, samples: samples, context: context, problems: &problems)
        problems.sort { $0.priority < $1.priority }
        data["problems"] = .array(problems.map { .string($0.kind.rawValue) })
        return (.object(data), problems)
    }

    /// Щелчок, провал и скачок громкости речи. `samples` — звук файла с секунды `start`.
    private static func audioFinding(
        _ samples: [Float], cut: Double, start: Double, context: CheckContext, problems: inout [CheckProblem]
    ) -> AgentJSONValue {
        let audio = SeamProbe.audio(samples: samples, sampleRate: SeamProbe.readSampleRate, cutOffset: cut - start)
        let jump = speechLevelJumpDB(samples, cut: cut, start: start, context: context)
        if audio.click {
            problems.append(
                CheckProblem(
                    time: cut, kind: .click,
                    evidence: "щелчок: перепад в \(String(format: "%.1f", audio.clickRatio)) раза резче обычного"))
        }
        if audio.dropoutMS > 0 {
            problems.append(
                CheckProblem(time: cut, kind: .dropout, evidence: "провал звука \(Int(audio.dropoutMS)) мс"))
        }
        if let jump, abs(jump) >= checkLevelJumpDB {
            problems.append(
                CheckProblem(
                    time: cut, kind: .levelJump,
                    evidence: "речь до склейки \(jump > 0 ? "громче" : "тише"), чем после, на "
                        + "\(String(format: "%.1f", abs(jump))) дБ"))
        }
        return .object([
            "clickRatio": .number((audio.clickRatio * 100).rounded() / 100), "click": .bool(audio.click),
            "dropoutMs": .number(audio.dropoutMS),
            "levelJumpDB": jump.map { .number(($0 * 10).rounded() / 10) } ?? .null,
        ])
    }

    /// Скачок громкости речи. Пауза у склейки — норма: если ближе 0,3 с с одной стороны нет слова
    /// ленты, сравнивать нечего (nil). Иначе сравнивается громкость слов ленты в пределах 1 с по каждую
    /// сторону: у короткого слова («с», «а») время из расшифровки часто лежит на паузе, и одно такое
    /// слово дало бы ложный скачок. Без расшифровки — звучащие окна (`SeamProbe.voicedLevelJumpDB`),
    /// а с музыкой в проекте не мерится вовсе.
    private static func speechLevelJumpDB(
        _ samples: [Float], cut: Double, start: Double, context: CheckContext
    ) -> Double? {
        let rate = SeamProbe.readSampleRate
        guard let words = context.words.expected else {
            return context.music
                ? nil : SeamProbe.voicedLevelJumpDB(samples: samples, sampleRate: rate, cutOffset: cut - start)
        }
        let edge = 0.005
        let before = words.filter { $0.end <= cut + edge && $0.end >= cut - SeamProbe.levelPhraseReach }
        let after = words.filter { $0.start >= cut - edge && $0.start <= cut + SeamProbe.levelPhraseReach }
        guard before.contains(where: { $0.end >= cut - SeamProbe.levelWordReach }),
            after.contains(where: { $0.start <= cut + SeamProbe.levelWordReach }),
            let beforeDB = SeamProbe.spansDB(
                samples: samples, sampleRate: rate,
                spans: before.map {
                    (max($0.start, cut - SeamProbe.levelPhraseReach) - start, min($0.end, cut) - start)
                }),
            let afterDB = SeamProbe.spansDB(
                samples: samples, sampleRate: rate,
                spans: after.map { (max($0.start, cut) - start, min($0.end, cut + SeamProbe.levelPhraseReach) - start) }
            )
        else { return nil }
        return beforeDB - afterDB
    }

    /// Чёрный кадр, которого нет в исходнике: тёмная сцена или затемнение, снятые так, — не дефект.
    /// Исходник не прочитать — дефект, только если чёрная ровно одна сторона склейки.
    private static func videoFinding(
        _ cut: CheckCut, context: CheckContext, problems: inout [CheckProblem]
    ) async throws -> AgentJSONValue {
        let times = [max(0, cut.time - 0.08), min(max(0, context.media.seconds - 0.01), cut.time + 0.04)]
        let luma = try await SeamProbe.meanLuma(asset: context.file, times: times)
        let fileBlack = luma.map(SeamProbe.isBlack(meanLuma:))
        let source = await sourceLuma(cut, assets: context.sourceAssets)
        let black: Bool
        if let source {
            black = zip(fileBlack, source).contains { $0 && !SeamProbe.isBlack(meanLuma: $1) }
        } else {
            black = fileBlack[0] != fileBlack[1]
        }
        if black {
            let seen = source.map { " (в исходнике \(format3($0[0])) и \(format3($0[1])))" } ?? ""
            problems.append(
                CheckProblem(
                    time: cut.time, kind: .black,
                    evidence: "чёрный кадр, которого нет в исходнике: яркость до \(format3(luma[0])), "
                        + "после \(format3(luma[1]))\(seen)"))
        }
        return .object([
            "lumaBefore": .number(rounded(luma[0])), "lumaAfter": .number(rounded(luma[1])),
            "sourceLumaBefore": source.map { .number(rounded($0[0])) } ?? .null,
            "sourceLumaAfter": source.map { .number(rounded($0[1])) } ?? .null,
            "black": .bool(black),
        ])
    }

    private static func format3(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    /// Яркость исходника в те же моменты ленты: за 0,08 с до конца клипа перед склейкой и через
    /// 0,04 с от начала клипа после неё. nil — исходник не прочитать.
    private static func sourceLuma(_ cut: CheckCut, assets: [URL: AVURLAsset]) async -> [Double]? {
        let before = max(cut.before.start, cut.before.end - 0.08)
        let after = min(cut.after.end, cut.after.start + 0.04)
        let beforeURL = cut.before.url, afterURL = cut.after.url
        let beforeAsset = assets[beforeURL] ?? AVURLAsset(url: beforeURL)
        if beforeURL == afterURL {
            return try? await SeamProbe.meanLuma(asset: beforeAsset, times: [before, after])
        }
        guard let first = try? await SeamProbe.meanLuma(asset: beforeAsset, times: [before]),
            let second = try? await SeamProbe.meanLuma(
                asset: assets[afterURL] ?? AVURLAsset(url: afterURL), times: [after]),
            let beforeLuma = first.first, let afterLuma = second.first
        else { return nil }
        return [beforeLuma, afterLuma]
    }

    /// Слова ленты, целиком лежащие в окне, против слов файла с запасом 0,3 с по краям:
    /// слово на краю окна, распознанное чуть шире, не должно считаться пропавшим. Пропавшее
    /// у склейки слово — дефект `cutWord`, только если в файле его место хотя бы на `checkWordLostDB`
    /// тише, чем в склейке проекта (`lostDB`): под музыкой распознавание теряет и слова, которые звучат.
    private static func wordsFinding(
        _ cut: Double, span: Range<Double>, samples: [Float]?, context: CheckContext,
        problems: inout [CheckProblem]
    ) async -> AgentJSONValue {
        guard let heard = context.words.heard, let expected = context.words.expected else { return .null }
        let (lower, upper) = (cut - context.window, cut + context.window)
        let finding = SeamProbe.words(
            expected: expected.filter { $0.start >= lower && $0.end <= upper },
            heard: heard.filter { $0.end > lower - 0.3 && $0.start < upper + 0.3 }, cut: cut)
        var lostDB: Double?
        if finding.suspect, let samples, let source = context.source,
            let project = try? await SeamProbe.samples(asset: source, from: span.lowerBound, to: span.upperBound)
        {
            lostDB = finding.atCut.compactMap { word in
                SeamProbe.wordDeficitDB(
                    file: samples, source: project.samples, sampleRate: project.sampleRate,
                    from: word.start - span.lowerBound, to: word.end - span.lowerBound)
            }.max()
        }
        if let lostDB, lostDB >= checkWordLostDB {
            problems.append(
                CheckProblem(
                    time: cut, kind: .cutWord,
                    evidence: "у склейки не слышно «\(finding.atCut.map(\.text).joined(separator: " "))»: "
                        + "в файле это место тише, чем в проекте, на \(String(format: "%.1f", lostDB)) дБ"))
        }
        return .object([
            "expected": .array(finding.expected.map { .string($0) }),
            "heard": .array(finding.heard.map { .string($0) }),
            "missing": .array(finding.missing.map { .string($0) }), "suspect": .bool(finding.suspect),
            "lostDB": lostDB.map { .number(($0 * 10).rounded() / 10) } ?? .null,
        ])
    }

    /// Сетка «до/после» для 8 склеек, проблемные первыми — через тот же путь, что `montazhka_frames`.
    private func cutsSheet(
        _ cuts: [Double], problems: [CheckProblem], project: Project, media: CheckMedia
    ) async -> AgentJSONValue {
        let flagged = Set(problems.map(\.time))
        let chosen = Array(
            (cuts.filter { flagged.contains($0) } + cuts.filter { !flagged.contains($0) })
                .prefix(Self.checkImageCuts))
        guard media.hasVideo, !chosen.isEmpty else { return .null }
        let sheet = await frames(
            AgentFramesRequest(
                target: AgentMediaTarget(projectID: project.id, filePath: media.url.path), aroundCuts: true,
                cuts: chosen))
        return sheet.data?["imagePath"] ?? .null
    }
}
