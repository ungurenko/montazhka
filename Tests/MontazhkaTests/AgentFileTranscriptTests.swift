import Foundation
import Testing

@testable import MontazhkaKit

/// `montazhka_transcript filePath=`: расшифровка любого файла во времени файла.
@Suite("Agent transcript of any file")
struct AgentFileTranscriptTests {
    /// Запоминает фоновые задачи вместо запуска настоящего процесса расшифровки.
    private actor JobRecorder {
        private(set) var requests: [AgentWorkerRequest] = []

        func start(_ request: AgentWorkerRequest) -> AgentResponse {
            requests.append(request)
            return .success(
                command: "submit",
                data: ["jobId": "job-1", "status": "running", "pollWith": "montazhka_get_job"])
        }
    }

    private struct Fixture {
        let root: URL
        let service: AgentService
        let recorder: JobRecorder
        let path: String
    }

    /// Тихий трёхсекундный файл без расшифровки; `words` — сколько слов положить в кэш (0 — не класть).
    private func fixture(words count: Int) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-file-transcript-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let video = root.appendingPathComponent("any.mov")
        try await TestVideoFactory.make(segments: [(duration: 3, loud: false)], to: video)
        let path = URL(fileURLWithPath: video.path).standardized.path
        let recorder = JobRecorder()
        let service = AgentService(baseDirectory: root, startJob: { await recorder.start($0) })
        if count > 0 {
            let media = MediaReference(path: path)
            // Слово каждые 0,3 с; после десятого слова пауза в секунду.
            let words = (0..<count).map { index in
                let start = 1.0 + Double(index) * 0.3 + (index >= 10 ? 1 : 0)
                return TranscriptWord(
                    sourceID: media.id, text: "слово\(index + 1)", start: start, end: start + 0.2, confidence: 1)
            }
            let cacheURL = await service.makeTranscriptStore().cacheURL(for: media)
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(TranscriptDocument(words: words)).write(to: cacheURL)
        }
        return Fixture(root: root, service: service, recorder: recorder, path: path)
    }

    private func fileRequest(_ path: String, from: Double? = nil) -> AgentTranscriptRequest {
        AgentTranscriptRequest(target: AgentMediaTarget(filePath: path), from: from, confirmModelDownload: true)
    }

    @Test("a cached file transcript pages in file time without timeline or cut markers")
    func cachedFileTranscriptPages() async throws {
        let fixture = try await fixture(words: 1600)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let first = await fixture.service.transcriptOrStartJob(fileRequest(fixture.path))

        #expect(first.ok, "\(String(describing: first.error))")
        #expect(first.data?["filePath"] == .string(fixture.path))
        #expect(first.data?["timeBase"] == .string("file"))
        #expect(first.data?["timeline"] == nil)
        #expect(first.data?["wordCount"] == .number(1500))
        // Слово 1501 (номер 1500 с нуля) начинается на 1 + 1500·0,3 + 1 = 452 с.
        #expect(first.data?["nextFrom"] == .number(452))
        guard case .string(let text)? = first.data?["text"] else {
            Issue.record("нет текста: \(String(describing: first.data))")
            return
        }
        let lines = text.split(separator: "\n")
        #expect(lines.first == "#1 1.00 1.20 слово1")
        #expect(lines.contains("--- пауза 1.1 с ---"))
        #expect(!text.contains("склейка"))
        #expect(await fixture.recorder.requests.isEmpty)

        let second = await fixture.service.transcriptOrStartJob(fileRequest(fixture.path, from: 452))
        #expect(second.data?["wordCount"] == .number(100))
        #expect(second.data?["nextFrom"] == .null)
        guard case .string(let rest)? = second.data?["text"] else {
            Issue.record("нет текста: \(String(describing: second.data))")
            return
        }
        #expect(rest.split(separator: "\n").first == "#1501 452.00 452.20 слово1501")
    }

    @Test("projectId and filePath together or neither are refused")
    func exactlyOneTarget() async throws {
        let fixture = try await fixture(words: 0)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let both = await fixture.service.transcriptOrStartJob(
            AgentTranscriptRequest(target: AgentMediaTarget(projectID: UUID(), filePath: fixture.path)))
        let neither = await fixture.service.transcriptOrStartJob(AgentTranscriptRequest(target: AgentMediaTarget()))

        #expect(both.error?.code == "INVALID_INPUT")
        #expect(neither.error?.code == "INVALID_INPUT")
        #expect(await fixture.recorder.requests.isEmpty)
    }

    @Test("a file without a transcript starts a background job with the project's response shape")
    func missingTranscriptStartsJob() async throws {
        let fixture = try await fixture(words: 0)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let response = await fixture.service.transcriptOrStartJob(fileRequest(fixture.path))

        #expect(response.ok, "\(String(describing: response.error))")
        #expect(response.command == "transcript")
        #expect(response.data?["jobId"] == .string("job-1"))
        #expect(response.data?["status"] == .string("running"))
        #expect(response.data?["next"] != nil)
        let requests = await fixture.recorder.requests
        guard requests.count == 1, case .transcribeFile(let path) = requests[0] else {
            Issue.record("задача не запущена: \(requests)")
            return
        }
        #expect(path == fixture.path)
    }

    @Test("the background part finishes from the cache and completes its run")
    func transcribeFileCompletesRun() async throws {
        let fixture = try await fixture(words: 12)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let run = try await fixture.service.runs.create(kind: .transcribe, sourcePaths: [fixture.path])

        let response = await fixture.service.transcribeFile(path: fixture.path, runMode: .existing(run.id))

        #expect(response.ok, "\(String(describing: response.error))")
        let finished = try await fixture.service.runs.load(id: run.id)
        #expect(finished.status == .completed)
        #expect(finished.summary?.contains("12") == true)
    }
}
