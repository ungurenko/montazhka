@preconcurrency import AVFoundation
import Foundation
import Testing

@testable import MontazhkaKit

/// `montazhka_check`: дефекты у каждой склейки готового файла.
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

    private struct Fixture {
        let root: URL
        let service: AgentService
        let recorder: JobRecorder
        let project: Project
        let source: MediaReference
    }

    /// Серый 4-секундный ролик с ровным тоном; лента — 0–1,5 и 2,5–4 с (одна склейка на 1,5 с ленты).
    /// Слова исходника: «раз» и «два» до склейки, «три» и «четыре» после неё.
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let video = root.appendingPathComponent("talk.mov")
        try await TestVideoFactory.make(segments: [(duration: 4, loud: true)], videoLuma: 128, to: video)
        let recorder = JobRecorder()
        let service = AgentService(baseDirectory: root, startJob: { await recorder.start($0) })
        let source = MediaReference(url: video)
        let project = Project(
            name: "Проверка",
            clips: [Clip(source: source, start: 0, end: 1.5), Clip(source: source, start: 2.5, end: 4)])
        try await service.store.save(project)
        try await cache(
            [("раз", 0.5, 0.9), ("два", 1.0, 1.45), ("три", 2.55, 2.95), ("четыре", 3.1, 3.6)], for: source,
            service: service)
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

    private func objects(_ value: AgentJSONValue?) -> [[String: AgentJSONValue]] {
        guard case .array(let items)? = value else { return [] }
        return items.compactMap { if case .object(let object) = $0 { object } else { nil } }
    }

    @Test("a fresh export is confirmed by its fingerprint and every cut gets audio, picture and loudness")
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
        let cut = try #require(objects(data["cuts"]).first)
        #expect(cut["time"] == .number(1.5))
        guard case .object(let audio)? = cut["audio"], case .object(let video)? = cut["video"] else {
            Issue.record("у склейки нет звука или картинки: \(cut)")
            return
        }
        #expect(audio["clickRatio"] != nil && audio["dropoutMs"] != nil && audio["levelJumpDB"] != nil)
        #expect(video["black"] == .bool(false))
        guard case .object(let loudness)? = data["loudness"], case .number = loudness["integratedLUFS"] else {
            Issue.record("нет громкости файла: \(String(describing: data["loudness"]))")
            return
        }
        guard case .object(let wordsCheck)? = data["wordsCheck"] else {
            Issue.record("нет wordsCheck")
            return
        }
        #expect(wordsCheck["status"] == .string("off"))
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
        #expect(response.error?.message == "Файл собран из старой ленты — экспортируйте заново")
    }

    @Test("a file without provenance matches by duration; a hole at the cut and a lost word are problems")
    func holeAndLostWordAreReported() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // «Готовый файл» той же длины (3 с), но с дырой в звуке 60 мс сразу после склейки.
        let file = fixture.root.appendingPathComponent("holed.mov")
        try await TestVideoFactory.make(
            segments: [
                (duration: 1.5, amplitude: 0.4), (duration: 0.06, amplitude: 0), (duration: 1.44, amplitude: 0.4),
            ],
            videoLuma: 128, to: file)
        let path = URL(fileURLWithPath: file.path).standardized.path
        // В файле не слышно «три» — первое слово после склейки.
        try await cache(
            [("раз", 0.5, 0.9), ("два", 1.0, 1.45), ("четыре", 2.1, 2.6)], for: MediaReference(path: path),
            service: fixture.service)

        let response = await fixture.service.check(request(fixture, file: path, words: true))

        #expect(response.ok, "\(String(describing: response.error))")
        let data = try #require(response.data)
        #expect(data["match"] == .string("unconfirmed"))
        let problems = objects(data["problems"])
        #expect(problems.first?["kind"] == .string("cutWord"), "обрезанное слово — первым: \(problems)")
        #expect(problems.contains { $0["kind"] == .string("dropout") && $0["time"] == .number(1.5) })
        let cut = try #require(objects(data["cuts"]).first)
        guard case .object(let words)? = cut["words"] else {
            Issue.record("у склейки нет слов: \(cut)")
            return
        }
        #expect(words["missing"] == .array(["три"]))
        #expect(words["suspect"] == .bool(true))
        guard case .object(let wordsCheck)? = data["wordsCheck"] else {
            Issue.record("нет wordsCheck")
            return
        }
        #expect(wordsCheck["status"] == .string("done"))
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
        guard case .object(let wordsCheck)? = response.data?["wordsCheck"] else {
            Issue.record("нет wordsCheck: \(String(describing: response.data))")
            return
        }
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
