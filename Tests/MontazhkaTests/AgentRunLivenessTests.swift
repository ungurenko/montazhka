import Foundation
import Testing

@testable import MontazhkaKit

/// Фоновая задача не висит в `running`, когда её исполнитель умер, и не получает
/// ложную ошибку, пока живой исполнитель долго работает.
@Suite("Background job liveness")
struct AgentRunLivenessTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-liveness-\(UUID().uuidString)", isDirectory: true)
    }

    /// Задача, которую запустили фоном: статус `running`, как после `submit`.
    private func runningJob(_ service: AgentService) async throws -> AgentRun {
        let run = try await service.runs.create(kind: .export, sourcePaths: [])
        try await service.runs.update(id: run.id) {
            $0.status = .running; $0.stage = "Фоновый процесс запущен"
        }
        return run
    }

    /// Сдвигает время последнего обновления в прошлое — как будто задача давно не сообщала о себе.
    private func age(_ run: AgentRun, in service: AgentService, by seconds: TimeInterval) async throws {
        let url = try await service.runs.artifactDirectory(id: run.id).appendingPathComponent("run.json")
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["updatedAt"] = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-seconds))
        try JSONSerialization.data(withJSONObject: json).write(to: url)
    }

    private func status(_ response: AgentResponse) -> String? {
        if case .string(let value)? = response.data?["status"] { value } else { nil }
    }

    @Test("a worker that died without a word is reported as interrupted")
    func deadWorkerIsInterrupted() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = AgentService(baseDirectory: root)
        let run = try await runningJob(service)
        // Исполнитель — отдельный «процесс» со своим хранилищем; он берёт задачу и умирает.
        var worker: AgentRunStore? = AgentRunStore(baseDirectory: await service.runs.baseDirectory)
        try await worker?.claim(id: run.id)
        #expect(status(await service.job(id: run.id)) == "running", "пока исполнитель жив — задача идёт")

        worker = nil
        let response = await service.job(id: run.id)

        #expect(status(response) == "failed")
        #expect(
            response.data?["summary"].map { "\($0)".contains("прерв") } == true, "\(String(describing: response.data))")
    }

    @Test("a live worker that has not reported for an hour is still running")
    func longLiveWorkerIsNotFailed() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = AgentService(baseDirectory: root)
        let run = try await runningJob(service)
        let worker = AgentRunStore(baseDirectory: await service.runs.baseDirectory)
        try await worker.claim(id: run.id)
        try await age(run, in: service, by: 3600)

        #expect(status(await service.job(id: run.id)) == "running")
        withExtendedLifetime(worker) {}
    }

    @Test("a submitted job whose worker never started is failed after a minute, not before")
    func workerThatNeverStarted() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = AgentService(baseDirectory: root)
        let fresh = try await runningJob(service)
        let stale = try await runningJob(service)
        try await age(stale, in: service, by: 300)

        #expect(status(await service.job(id: fresh.id)) == "running", "исполнитель ещё запускается")
        #expect(status(await service.job(id: stale.id)) == "failed")
    }

    @Test("a late progress event does not bring a finished job back to running")
    func finishedJobStaysFinished() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = AgentService(baseDirectory: root)
        let run = try await runningJob(service)
        try await service.runs.update(id: run.id) {
            $0.status = .completed; $0.progress = 1; $0.stage = "Экспорт готов"
        }

        try await service.runs.update(id: run.id) {
            $0.status = .running; $0.progress = 0.4
        }
        try await service.runs.update(id: run.id) { $0.stage = "Записываю файл" }
        try await service.runs.update(id: run.id) {
            $0.status = .failed; $0.summary = "прервался"
        }
        try await service.runs.update(id: run.id) { $0.artifacts["result"] = "/tmp/result.json" }

        let reloaded = try await service.runs.load(id: run.id)
        #expect(reloaded.status == .completed, "ни поздний прогресс, ни поздняя сверка не меняют итог")
        #expect(reloaded.progress == 1)
        #expect(reloaded.stage == "Экспорт готов", "поздний этап не затирает итоговый")
        #expect(reloaded.summary == nil)
        #expect(reloaded.artifacts["result"] == "/tmp/result.json", "итоговые файлы дописываются")
    }
}
