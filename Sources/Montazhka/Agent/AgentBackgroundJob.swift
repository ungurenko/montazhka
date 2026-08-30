import Foundation

enum AgentWorkerRequest: Codable, Sendable {
    case edit(AgentEditRequest)
    case shorts(sourcePath: String, confirmModelDownload: Bool)
    case export(projectID: UUID, outputPath: String?, quality: String, final: Bool, confirmFinal: Bool, overwrite: Bool)
}

enum AgentBackgroundJob {
    static func submit(_ request: AgentWorkerRequest) async throws -> AgentResponse {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Montazhka/AgentRuns", isDirectory: true)
        let store = AgentRunStore(baseDirectory: base)
        let kind: AgentRunKind
        let sources: [String]
        switch request {
        case .edit(let value):
            kind = value.projectID == nil ? .editVideo : .editProject
            sources = value.sourcePaths
        case .shorts(let path, _): kind = .makeShorts; sources = [path]
        case .export: kind = .export; sources = []
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
        return .success(
            command: "submit",
            data: [
                "jobId": .string(run.id.uuidString), "status": .string("running"),
                "pollWith": .string("montazhka_get_job"),
            ])
    }

    static func work(jobID: UUID, requestURL: URL) async -> AgentResponse {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Montazhka/AgentRuns", isDirectory: true)
        let store = AgentRunStore(baseDirectory: base)
        do {
            let request = try JSONDecoder().decode(AgentWorkerRequest.self, from: Data(contentsOf: requestURL))
            let service = AgentService()
            let result: AgentResponse
            switch request {
            case .edit(let edit): result = await service.edit(edit, runMode: .existing(jobID))
            case .shorts(let path, let confirm):
                result = await service.makeShorts(
                    sourcePath: path, confirmModelDownload: confirm,
                    runMode: .existing(jobID))
            case .export(let id, let path, let quality, let final, let confirm, let overwrite):
                result = await service.export(
                    projectID: id, outputPath: path, quality: quality,
                    final: final, confirmFinal: confirm, overwrite: overwrite,
                    runMode: .existing(jobID))
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
