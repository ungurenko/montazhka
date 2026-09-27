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

/// Слова для сверки: слова ленты (время ленты = время файла) и слова файла.
/// `heard == nil` — сверки нет, причина в `status`.
private struct CheckWords: Sendable {
    var expected: [SeamWord] = []
    var heard: [SeamWord]?
    let status: AgentJSONValue
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
    /// Скачок громкости у склейки меньше этого — обычная разница фраз, не проблема.
    static let checkLevelJumpDB = 10.0
    /// Файл без отпечатка ленты считается этим проектом, если длительности сходятся.
    static let checkDurationTolerance = 0.25
    static let fileMismatchMessage = "Файл собран из старой ленты — экспортируйте заново"

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
            let allCuts = TimelineEditOps.starts(of: project.clips).dropFirst().filter { $0 >= lower && $0 <= upper }
            let cuts = Array(allCuts.prefix(Self.checkCutLimit))
            let words = await checkWords(request, project: project, path: path)

            var results: [AgentJSONValue] = []
            var problems: [CheckProblem] = []
            for cut in cuts {
                let (result, found) = try await Self.checkCut(
                    cut, media: media, asset: asset, window: window, words: words)
                results.append(result)
                problems += found
            }
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
                    "loudness": media.hasAudio ? await Self.fileLoudness(media.url) : .null,
                    "wordsCheck": words.status,
                    "imagePath": await cutsSheet(cuts, problems: problems, project: project, media: media),
                    "nextFrom": allCuts.count > cuts.count ? .number(Self.rounded(allCuts[cuts.count])) : .null,
                ])
        } catch { return failure("check", error) }
    }

    /// "confirmed" — в файле отпечаток этой ленты; "unconfirmed" — отпечатка нет, но длительность
    /// сходится; nil — файл собран из другой ленты.
    private static func fileMatch(_ media: CheckMedia, project: Project) async -> String? {
        if let stamp = await ExportProvenance.read(url: media.url) {
            return stamp == AgentWordCuts.fingerprint(project.clips) ? "confirmed" : nil
        }
        return abs(media.seconds - project.totalDuration) <= checkDurationTolerance ? "unconfirmed" : nil
    }

    /// Слова ленты и файла из кэша расшифровок. Нет расшифровки файла — запускает её в фоне
    /// (модель без согласия не качает: тогда сверка выключена и сказано почему).
    private func checkWords(_ request: AgentCheckRequest, project: Project, path: String) async -> CheckWords {
        func off(_ reason: String) -> CheckWords {
            CheckWords(status: .object(["status": "off", "reason": .string(reason)]))
        }
        guard request.words else { return off("Сверка слов выключена (words=false).") }
        guard let map = try? await cachedTimelineTranscript(for: project) else {
            return off("Нет расшифровки проекта: вызовите montazhka_transcript projectId и дождитесь её.")
        }
        let expected = map.words.map { SeamWord(text: $0.text, start: $0.timelineStart, end: $0.timelineEnd) }
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
        _ cut: Double, media: CheckMedia, asset: AVAsset, window: Double, words: CheckWords
    ) async throws -> (AgentJSONValue, [CheckProblem]) {
        var problems: [CheckProblem] = []
        var data: [String: AgentJSONValue] = ["time": .number(rounded(cut)), "audio": .null, "video": .null]
        if media.hasAudio {
            let start = max(0, cut - window)
            let read = try await SeamProbe.samples(url: media.url, from: start, to: min(media.seconds, cut + window))
            let audio = SeamProbe.audio(samples: read.samples, sampleRate: read.sampleRate, cutOffset: cut - start)
            data["audio"] = .object([
                "clickRatio": .number((audio.clickRatio * 100).rounded() / 100), "click": .bool(audio.click),
                "dropoutMs": .number(audio.dropoutMS), "levelJumpDB": .number((audio.levelJumpDB * 10).rounded() / 10),
            ])
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
            if abs(audio.levelJumpDB) >= checkLevelJumpDB {
                problems.append(
                    CheckProblem(
                        time: cut, kind: .levelJump,
                        evidence: "громкость до склейки \(audio.levelJumpDB > 0 ? "выше" : "ниже") на "
                            + "\(String(format: "%.1f", abs(audio.levelJumpDB))) дБ"))
            }
        }
        if media.hasVideo {
            let times = [max(0, cut - 0.08), min(max(0, media.seconds - 0.01), cut + 0.04)]
            let luma = try await SeamProbe.meanLuma(asset: asset, times: times)
            let black = luma.contains(where: SeamProbe.isBlack(meanLuma:))
            data["video"] = .object([
                "lumaBefore": .number(rounded(luma[0])), "lumaAfter": .number(rounded(luma[1])), "black": .bool(black),
            ])
            if black {
                problems.append(
                    CheckProblem(
                        time: cut, kind: .black,
                        evidence: "чёрный кадр: яркость до \(String(format: "%.3f", luma[0])), "
                            + "после \(String(format: "%.3f", luma[1]))"))
            }
        }
        data["words"] = wordsFinding(cut, window: window, words: words, problems: &problems)
        problems.sort { $0.priority < $1.priority }
        data["problems"] = .array(problems.map { .string($0.kind.rawValue) })
        return (.object(data), problems)
    }

    /// Слова ленты, целиком лежащие в окне, против слов файла с запасом 0,3 с по краям:
    /// слово на краю окна, распознанное чуть шире, не должно считаться пропавшим.
    private static func wordsFinding(
        _ cut: Double, window: Double, words: CheckWords, problems: inout [CheckProblem]
    ) -> AgentJSONValue {
        guard let heard = words.heard else { return .null }
        let (lower, upper) = (cut - window, cut + window)
        let finding = SeamProbe.words(
            expected: words.expected.filter { $0.start >= lower && $0.end <= upper },
            heard: heard.filter { $0.end > lower - 0.3 && $0.start < upper + 0.3 }, cut: cut)
        if finding.suspect {
            problems.append(
                CheckProblem(
                    time: cut, kind: .cutWord,
                    evidence: "у склейки не слышно: «\(finding.missing.joined(separator: " "))»"))
        }
        return .object([
            "expected": .array(finding.expected.map { .string($0) }),
            "heard": .array(finding.heard.map { .string($0) }),
            "missing": .array(finding.missing.map { .string($0) }), "suspect": .bool(finding.suspect),
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
