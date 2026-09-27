@preconcurrency import AVFoundation
import Foundation
import Testing

@testable import MontazhkaKit

/// `montazhka_check`: дефекты у каждой склейки готового файла. Агент и критик чинят «технические»
/// проблемы сами, поэтому здоровая склейка (пауза, тёмная сцена, слово под музыкой) должна
/// проходить молча, а настоящий дефект — находиться.
@Suite("Agent checks cuts of a finished file")
struct AgentCheckTests {
    /// Запоминает фоновые задачи вместо запуска настоящего процесса расшифровки.
    private actor JobRecorder {
        private(set) var requests: [AgentWorkerRequest] = []

        func start(_ request: AgentWorkerRequest) -> AgentResponse {
            requests.append(request)
            return .success(
                command: "submit",
                data: ["jobId": "job-check", "status": "running", "pollWith": "montazhka_get_job"])
        }
    }

    /// Исходник и лента. По умолчанию — серый 4-секундный ролик с ровным тоном, лента 0–1,5 и 2,5–4 с
    /// (одна склейка на 1,5 с ленты); слова «раз» и «два» до склейки, «три» и «четыре» после неё.
    private struct Setup {
        var segments: [(duration: Double, amplitude: Double)] = [(duration: 4, amplitude: 0.4)]
        var luma: UInt8 = 128
        var clips: [(start: Double, end: Double)] = [(0, 1.5), (2.5, 4)]
        var words: [(String, Double, Double)] = [
            ("раз", 0.5, 0.9), ("два", 1.0, 1.45), ("три", 2.55, 2.95), ("четыре", 3.1, 3.6),
        ]
        var music = false
    }

    private struct Fixture {
        let root: URL
        let service: AgentService
        let recorder: JobRecorder
        let project: Project
        let source: MediaReference
    }

    private func fixture(_ setup: Setup = Setup()) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let video = root.appendingPathComponent("talk.mov")
        try await TestVideoFactory.make(segments: setup.segments, videoLuma: setup.luma, to: video)
        let recorder = JobRecorder()
        let service = AgentService(baseDirectory: root, startJob: { await recorder.start($0) })
        let source = MediaReference(url: video)
        var project = Project(
            name: "Проверка", clips: setup.clips.map { Clip(source: source, start: $0.start, end: $0.end) })
        if setup.music {
            let track = try #require(MusicLibrary.tracks.first)
            project.music = MusicSettings(
                enabled: true, trackID: track.id, volume: 30, eqEnabled: false, ducking: true)
        }
        try await service.store.save(project)
        try await cache(setup.words, for: source, service: service)
        return Fixture(root: root, service: service, recorder: recorder, project: project, source: source)
    }

    private func cache(
        _ words: [(String, Double, Double)], for media: MediaReference, service: AgentService
    ) async throws {
        let transcript = words.map {
            TranscriptWord(sourceID: media.id, text: $0.0, start: $0.1, end: $0.2, confidence: 1)
        }
        let cacheURL = await service.makeTranscriptStore().cacheURL(for: media)
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(TranscriptDocument(words: transcript)).write(to: cacheURL)
    }

    private func request(
        _ fixture: Fixture, file: String?, words: Bool = false
    ) -> AgentCheckRequest {
        AgentCheckRequest(
            projectID: fixture.project.id, filePath: file, words: words, confirmModelDownload: true)
    }

    private func export(_ fixture: Fixture) async throws -> String {
        let output = fixture.root.appendingPathComponent("out.mp4")
        let response = await fixture.service.export(
            projectID: fixture.project.id, outputPath: output.path, quality: "compact",
            final: false, confirmFinal: false, overwrite: false)
        #expect(response.ok, "\(String(describing: response.error))")
        return output.path
    }

    /// «Готовый файл» без отпечатка ленты: звук и картинка — как заданы.
    private func syntheticFile(
        _ fixture: Fixture, _ segments: [(duration: Double, amplitude: Double)]
    ) async throws -> String {
        let file = fixture.root.appendingPathComponent("made-\(UUID().uuidString).mov")
        try await TestVideoFactory.make(segments: segments, videoLuma: 128, to: file)
        return URL(fileURLWithPath: file.path).standardized.path
    }

    private func objects(_ value: AgentJSONValue?) -> [[String: AgentJSONValue]] {
        guard case .array(let items)? = value else { return [] }
        return items.compactMap { if case .object(let object) = $0 { object } else { nil } }
    }

    private func part(_ cut: [String: AgentJSONValue]?, _ key: String) -> [String: AgentJSONValue] {
        if case .object(let object)? = cut?[key] { object } else { [:] }
    }

    private func number(_ value: AgentJSONValue?) -> Double? {
        if case .number(let number)? = value { number } else { nil }
    }

    @Test("a fresh export is confirmed, every cut gets audio, picture and loudness, and nothing is reported")
    func freshExportIsConfirmed() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let path = try await export(fixture)

        let response = await fixture.service.check(request(fixture, file: path))

        #expect(response.ok, "\(String(describing: response.error))")
        let data = try #require(response.data)
        #expect(data["match"] == .string("confirmed"))
        #expect(data["cutCount"] == .number(1))
        #expect(data["window"] == .number(1.5))
        #expect(data["nextFrom"] == .null)
        #expect(data["problems"] == .array([]), "чистая склейка — без проблем")
        let cut = try #require(objects(data["cuts"]).first)
        #expect(cut["time"] == .number(1.5))
        #expect(cut["problems"] == .array([]))
        let audio = part(cut, "audio")
        #expect(audio["clickRatio"] != nil && audio["dropoutMs"] != nil)
        #expect(abs(number(audio["levelJumpDB"]) ?? 99) < 3, "слова по обе стороны звучат одинаково")
        #expect(part(cut, "video")["black"] == .bool(false))
        guard case .object(let loudness)? = data["loudness"], case .number = loudness["integratedLUFS"] else {
            Issue.record("нет громкости файла: \(String(describing: data["loudness"]))")
            return
        }
        #expect(part(data, "wordsCheck")["status"] == .string("off"))
        guard case .string(let image)? = data["imagePath"] else {
            Issue.record("нет сетки кадров у склеек")
            return
        }
        #expect(FileManager.default.fileExists(atPath: image))

        let heard = await fixture.service.audio(
            target: AgentMediaTarget(filePath: path), from: nil, to: nil, buckets: nil)
        guard case .object(let fileLoudness)? = heard.data?["loudness"], case .number = fileLoudness["integratedLUFS"]
        else {
            Issue.record("montazhka_audio с filePath без громкости: \(String(describing: heard.data))")
            return
        }
    }

    @Test("a clean cut with a natural pause on one side is silent, with and without a transcript")
    func pauseAtCutIsClean() async throws {
        // Речь 0–1 с, пауза 1–1,4 с, речь дальше. Склейка на 1,3 с ленты: до неё 0,3 с паузы, после — сразу речь.
        let fixture = try await fixture(
            Setup(
                segments: [
                    (duration: 1, amplitude: 0.4), (duration: 0.4, amplitude: 0), (duration: 2.6, amplitude: 0.4),
                ],
                clips: [(0, 1.3), (2, 4)], words: [("раз", 0.3, 0.9), ("два", 2.1, 2.6), ("три", 3.0, 3.5)]))
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let path = try await export(fixture)

        let withWords = await fixture.service.check(request(fixture, file: path))

        #expect(withWords.ok, "\(String(describing: withWords.error))")
        #expect(withWords.data?["problems"] == .array([]), "\(String(describing: withWords.data?["cuts"]))")
        #expect(part(objects(withWords.data?["cuts"]).first, "audio")["levelJumpDB"] == .null)

        let transcript = await fixture.service.makeTranscriptStore().cacheURL(for: fixture.source)
        try FileManager.default.removeItem(at: transcript)
        let withoutWords = await fixture.service.check(request(fixture, file: path))

        #expect(withoutWords.ok, "\(String(describing: withoutWords.error))")
        #expect(withoutWords.data?["problems"] == .array([]), "\(String(describing: withoutWords.data?["cuts"]))")
        #expect(part(objects(withoutWords.data?["cuts"]).first, "audio")["levelJumpDB"] == .null)
    }

    @Test("a short word whose transcript time lies on the pause after the cut is not a level jump")
    func misplacedShortWordIsNotLevelJump() async throws {
        // После склейки 0,2 с паузы, расшифровка поставила на неё короткое «с»; дальше речь той же громкости.
        let fixture = try await fixture(
            Setup(
                segments: [
                    (duration: 2.5, amplitude: 0.4), (duration: 0.2, amplitude: 0), (duration: 1.3, amplitude: 0.4),
                ],
                words: [
                    ("раз", 0.5, 0.9), ("два", 1.0, 1.45), ("с", 2.5, 2.7), ("таким", 2.75, 3.2), ("темпом", 3.3, 3.8),
                ]))
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let path = try await export(fixture)

        let response = await fixture.service.check(request(fixture, file: path))

        #expect(response.ok, "\(String(describing: response.error))")
        #expect(response.data?["problems"] == .array([]), "\(String(describing: response.data?["cuts"]))")
        let jump = number(part(objects(response.data?["cuts"]).first, "audio")["levelJumpDB"])
        #expect(abs(jump ?? 99) < 3)
    }

    @Test("a dark video that is dark in the source too is not a black frame")
    func darkVideoIsNotBlack() async throws {
        let fixture = try await fixture(Setup(luma: 5))
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let path = try await export(fixture)

        let response = await fixture.service.check(request(fixture, file: path))

        #expect(response.ok, "\(String(describing: response.error))")
        let video = part(objects(response.data?["cuts"]).first, "video")
        #expect((number(video["lumaBefore"]) ?? 1) < SeamProbe.blackLuma, "кадр действительно тёмный: \(video)")
        #expect(video["black"] == .bool(false))
        #expect(!objects(response.data?["problems"]).contains { $0["kind"] == .string("black") })
    }

    @Test("a black frame introduced only at the cut is reported")
    func blackAtCutIsReported() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let gray = URL(fileURLWithPath: fixture.source.lastKnownPath)
        let blackURL = fixture.root.appendingPathComponent("black.mov")
        try await TestVideoFactory.make(segments: [(duration: 1, amplitude: 0.4)], videoLuma: 0, to: blackURL)
        // Та же длина 3 с, что у ленты, но 1,45–1,6 с — чёрные кадры, которых в исходнике нет.
        let built = await CompositionBuilder.build(clips: [
            Clip(sourceURL: gray, start: 0, end: 1.45), Clip(sourceURL: blackURL, start: 0, end: 0.15),
            Clip(sourceURL: gray, start: 2.6, end: 4),
        ])
        let input = ExportInput(composition: built.composition, audioMix: built.audioMix)
        let output = fixture.root.appendingPathComponent("black-at-cut.mp4")
        try await Transcoder.export(
            input: input, settings: try await Transcoder.settings(for: .compact, input: input), to: output
        ) { _ in }

        let response = await fixture.service.check(request(fixture, file: output.path))

        #expect(response.ok, "\(String(describing: response.error))")
        #expect(objects(response.data?["problems"]).contains { $0["kind"] == .string("black") })
        let video = part(objects(response.data?["cuts"]).first, "video")
        #expect((number(video["sourceLumaAfter"]) ?? 0) > SeamProbe.blackLuma)
    }

    @Test("after a timeline edit the exported file is reported as built from the old timeline")
    func staleFileIsRefused() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let path = try await export(fixture)
        var split = AgentEditOperation(op: "split")
        split.at = 0.5
        #expect(await fixture.service.applyEdits(projectID: fixture.project.id, operations: [split]).ok)

        let response = await fixture.service.check(request(fixture, file: path))

        #expect(response.error?.code == "FILE_PROJECT_MISMATCH")
        #expect(response.error?.message == "Файл собран из другой версии проекта — экспортируйте заново")
    }

    /// Что меняет готовый файл, кроме ленты.
    enum Reshape: String, CaseIterable {
        case music, overlay, burnSubtitles
    }

    @Test(
        "music, an animation or burned subtitles changed after export make the file stale", arguments: Reshape.allCases)
    func reshapedProjectRefusesFile(_ change: Reshape) async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let path = try await export(fixture)
        switch change {
        case .music:
            var project = try await fixture.service.store.load(id: fixture.project.id)
            project.music = MusicSettings(enabled: true, trackID: try #require(MusicLibrary.tracks.first).id)
            try await fixture.service.store.save(project)
        case .overlay:
            var project = try await fixture.service.store.load(id: fixture.project.id)
            project.overlays.append(
                ProjectOverlay(
                    id: UUID(), media: MediaReference(path: fixture.root.appendingPathComponent("a.mov").path),
                    anchor: OverlayAnchor(sourceID: fixture.source.id, sourceTime: 0.5, wordText: nil), align: .start,
                    payoffAt: 0, duration: 1, position: .full, scale: 1))
            try await fixture.service.store.save(project)
        case .burnSubtitles:
            var burn = AgentEditOperation(op: "setSubtitles")
            burn.on = true
            #expect(await fixture.service.applyEdits(projectID: fixture.project.id, operations: [burn]).ok)
        }

        let response = await fixture.service.check(request(fixture, file: path))

        #expect(response.error?.code == "FILE_PROJECT_MISMATCH")
    }

    @Test("one-off export options of the agent keep the file confirmed: it is still this project version")
    func oneOffExportOptionsStayConfirmed() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let output = fixture.root.appendingPathComponent("out.mp4")
        let exported = await fixture.service.export(
            projectID: fixture.project.id, outputPath: output.path, quality: "compact", final: false,
            confirmFinal: false, overwrite: false, normalizeLoudness: false, burnSubtitles: true)
        #expect(exported.ok, "\(String(describing: exported.error))")

        let response = await fixture.service.check(request(fixture, file: output.path))

        #expect(response.data?["match"] == .string("confirmed"), "\(String(describing: response.error))")
    }

    @Test("a hole at the cut is a dropout; a word the recognizer missed while it still sounds is not cutWord")
    func holeIsDropout() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // Та же длина (3 с), но дыра в звуке 60 мс сразу после склейки.
        let path = try await syntheticFile(
            fixture,
            [(duration: 1.5, amplitude: 0.4), (duration: 0.06, amplitude: 0), (duration: 1.44, amplitude: 0.4)])
        // Повторная расшифровка не расслышала «три», хотя оно звучит.
        try await cache(
            [("раз", 0.5, 0.9), ("два", 1.0, 1.45), ("четыре", 2.1, 2.6)], for: MediaReference(path: path),
            service: fixture.service)

        let response = await fixture.service.check(request(fixture, file: path, words: true))

        #expect(response.ok, "\(String(describing: response.error))")
        let data = try #require(response.data)
        #expect(data["match"] == .string("unconfirmed"))
        #expect(part(data, "wordsCheck")["status"] == .string("done"))
        let problems = objects(data["problems"])
        #expect(problems.contains { $0["kind"] == .string("dropout") && $0["time"] == .number(1.5) })
        #expect(!problems.contains { $0["kind"] == .string("cutWord") }, "\(problems)")
        let words = part(objects(data["cuts"]).first, "words")
        #expect(words["missing"] == .array(["три"]))
        #expect(words["suspect"] == .bool(true))
        #expect((number(words["lostDB"]) ?? 99) < AgentService.checkWordLostDB)
    }

    @Test("a word that is really gone from the file at the cut is cutWord, first")
    func removedWordIsCutWord() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // На месте «три» (1,55–1,95 с ленты) в файле тишина.
        let path = try await syntheticFile(
            fixture,
            [(duration: 1.55, amplitude: 0.4), (duration: 0.4, amplitude: 0), (duration: 1.05, amplitude: 0.4)])
        try await cache(
            [("раз", 0.5, 0.9), ("два", 1.0, 1.45), ("четыре", 2.1, 2.6)], for: MediaReference(path: path),
            service: fixture.service)

        let response = await fixture.service.check(request(fixture, file: path, words: true))

        #expect(response.ok, "\(String(describing: response.error))")
        let problems = objects(response.data?["problems"])
        #expect(problems.first?["kind"] == .string("cutWord"), "обрезанное слово — первым: \(problems)")
        let words = part(objects(response.data?["cuts"]).first, "words")
        #expect((number(words["lostDB"]) ?? 0) >= AgentService.checkWordLostDB)
    }

    @Test("speech under music: a word the file transcript misses while the audio is intact is not cutWord")
    func missedWordUnderMusicIsNotCutWord() async throws {
        let fixture = try await fixture(Setup(music: true))
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let path = try await export(fixture)
        try await cache(
            [("раз", 0.5, 0.9), ("два", 1.0, 1.45), ("четыре", 2.1, 2.6)], for: MediaReference(path: path),
            service: fixture.service)

        let response = await fixture.service.check(request(fixture, file: path, words: true))

        #expect(response.ok, "\(String(describing: response.error))")
        let words = part(objects(response.data?["cuts"]).first, "words")
        #expect(words["missing"] == .array(["три"]))
        #expect(!objects(response.data?["problems"]).contains { $0["kind"] == .string("cutWord") }, "\(words)")
    }

    @Test("a file of another length without provenance is refused")
    func otherLengthIsRefused() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let response = await fixture.service.check(request(fixture, file: fixture.source.lastKnownPath))

        #expect(response.error?.code == "FILE_PROJECT_MISMATCH")
    }

    @Test("without a cached file transcript the words check starts a background job")
    func missingFileTranscriptStartsJob() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let path = try await export(fixture)

        let response = await fixture.service.check(request(fixture, file: path, words: true))

        #expect(response.ok, "\(String(describing: response.error))")
        let wordsCheck = part(response.data, "wordsCheck")
        #expect(wordsCheck["status"] == .string("pending"))
        #expect(wordsCheck["jobId"] == .string("job-check"))
        let requests = await fixture.recorder.requests
        guard requests.count == 1, case .transcribeFile(let started) = requests[0] else {
            Issue.record("расшифровка файла не запущена: \(requests)")
            return
        }
        #expect(started == URL(fileURLWithPath: path).standardized.path)
    }

    @Test("a normal project without filePath is refused with INVALID_INPUT")
    func normalProjectNeedsFile() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let response = await fixture.service.check(request(fixture, file: nil))

        #expect(response.error?.code == "INVALID_INPUT")
    }
}
