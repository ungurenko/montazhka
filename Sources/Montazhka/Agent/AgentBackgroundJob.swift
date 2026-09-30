import CryptoKit
import Foundation

enum AgentWorkerRequest: Codable, Sendable {
    case edit(AgentEditRequest)
    case shorts(AgentShortsRequest)
    case export(
        projectID: UUID, outputPath: String?, quality: String, final: Bool, confirmFinal: Bool, overwrite: Bool,
        normalizeLoudness: Bool?, burnSubtitles: Bool?)
    case transcribe(projectID: UUID)
    /// Расшифровка любого файла, не проекта.
    case transcribeFile(path: String)
}

enum AgentBackgroundJob {
    /// Папка фоновых задач агента.
    static var runsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Montazhka/AgentRuns", isDirectory: true)
    }

    static func submit(_ request: AgentWorkerRequest) async throws -> AgentResponse {
        let store = AgentRunStore(baseDirectory: runsDirectory)
        let transcriptionKey = try await transcriptionKey(for: request)
        let submissionLock: FileLock?
        if let transcriptionKey {
            submissionLock = try await FileLock.acquire(
                guarding: runsDirectory.appendingPathComponent("transcription-submit"))
            if let run = try await store.activeTranscription(key: transcriptionKey) {
                return submitted(run)
            }
        } else {
            submissionLock = nil
        }
        defer { withExtendedLifetime(submissionLock) {} }
        let kind: AgentRunKind
        let sources: [String]
        switch request {
        case .edit(let value):
            kind = value.projectID == nil ? .editVideo : .editProject
            sources = value.sourcePaths
        case .shorts: kind = .makeShorts; sources = []
        case .export: kind = .export; sources = []
        case .transcribe: kind = .transcribe; sources = []
        case .transcribeFile(let path): kind = .transcribe; sources = [path]
        }
        let run = try await store.create(kind: kind, sourcePaths: sources)
        let directory = try await store.artifactDirectory(id: run.id)
        let requestURL = directory.appendingPathComponent("request.json")
        try JSONEncoder().encode(request).write(to: requestURL, options: .atomic)
        let logURL = directory.appendingPathComponent("worker.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["agent", "worker", "--job", run.id.uuidString, "--request", requestURL.path]
        process.standardOutput = log; process.standardError = log
        try await store.update(id: run.id) {
            $0.status = .running; $0.stage = "Фоновый процесс запущен"; $0.artifacts["log"] = logURL.path
            if let transcriptionKey { $0.transcriptionKey = transcriptionKey }
        }
        do {
            try process.run()
        } catch {
            try? await store.update(id: run.id) {
                $0.status = .failed; $0.stage = "Не удалось запустить фоновый процесс"
                $0.error = AgentErrorPayload(code: "WORKER_LAUNCH_FAILED", message: error.localizedDescription)
            }
            throw error
        }
        return submitted(run)
    }

    private static func submitted(_ run: AgentRun) -> AgentResponse {
        .success(
            command: "submit",
            data: [
                "jobId": .string(run.id.uuidString), "status": .string("running"),
                "pollWith": .string("montazhka_get_job"),
            ])
    }

    private static func transcriptionKey(for request: AgentWorkerRequest) async throws -> String? {
        let sources: [String]
        switch request {
        case .transcribeFile(let path): sources = [path]
        case .transcribe(let id):
            let project = try await ProjectStore().load(id: id)
            sources = Array(Set(project.clips.map(\.sourcePath))).sorted()
        default: return nil
        }
        let keys = sources.map { TranscriptStore.cacheKey(for: $0) }
        let data = try JSONEncoder().encode(keys)
        return SHA256.hash(data: data).hex
    }

    static func work(jobID: UUID, requestURL: URL) async -> AgentResponse {
        let store = AgentRunStore(baseDirectory: runsDirectory)
        do { try await store.claim(id: jobID) } catch {
            return .failure(command: "worker", code: "WORKER_CLAIM_FAILED", message: error.localizedDescription)
        }
        do {
            let request = try JSONDecoder().decode(AgentWorkerRequest.self, from: Data(contentsOf: requestURL))
            let service = AgentService(runs: store)
            let result: AgentResponse
            switch request {
            case .edit(let edit): result = await service.edit(edit, runMode: .existing(jobID))
            case .shorts(let request):
                result = await service.makeShorts(request, runMode: .existing(jobID))
            case .export(let id, let path, let quality, let final, let confirm, let overwrite, let loudness, let burn):
                result = await service.export(
                    projectID: id, outputPath: path, quality: quality,
                    final: final, confirmFinal: confirm, overwrite: overwrite,
                    normalizeLoudness: loudness, burnSubtitles: burn,
                    runMode: .existing(jobID))
            case .transcribe(let id):
                result = await service.transcribe(projectID: id, runMode: .existing(jobID))
            case .transcribeFile(let path):
                result = await service.transcribeFile(path: path, runMode: .existing(jobID))
            }
            let directory = try await store.artifactDirectory(id: jobID)
            let resultURL = directory.appendingPathComponent("result.json")
            try JSONEncoder().encode(result).write(to: resultURL, options: .atomic)
            try await store.update(id: jobID) {
                $0.artifacts["result"] = resultURL.path
                if !result.ok {
                    $0.status = result.error?.code == "MODEL_DOWNLOAD_REQUIRED" ? .waitingForApproval : .failed
                    $0.stage = $0.status == .waitingForApproval ? "Нужно подтверждение" : "Ошибка"
                    $0.summary = result.error?.message
                    $0.error = result.error
                }
            }
            return result
        } catch {
            try? await store.update(id: jobID) {
                $0.status = .failed; $0.stage = "Ошибка"; $0.summary = error.localizedDescription
                $0.error = AgentErrorPayload(code: "WORKER_FAILED", message: error.localizedDescription)
            }
            return .failure(command: "worker", code: "WORKER_FAILED", message: error.localizedDescription)
        }
    }
}
