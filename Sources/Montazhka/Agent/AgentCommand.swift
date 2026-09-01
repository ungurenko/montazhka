import Foundation
import MCP

enum AgentCommand {
    static func run(arguments: [String]) async -> Int32 {
        let args = Array(arguments.dropFirst())
        if args.first == "mcp" || (args.first == "agent" && args.dropFirst().first == "mcp") {
            do {
                try await AgentMCPServer().run()
                return 0
            } catch {
                FileHandle.standardError.write(Data("MCP error: \(error.localizedDescription)\n".utf8))
                return 1
            }
        }
        let commandArgs = args.first == "agent" ? Array(args.dropFirst()) : args
        if commandArgs.first == "worker",
            let jobID = value("--job", in: commandArgs).flatMap(UUID.init(uuidString:)),
            let requestPath = value("--request", in: commandArgs)
        {
            let response = await AgentBackgroundJob.work(
                jobID: jobID, requestURL: URL(fileURLWithPath: requestPath))
            write(response)
            return response.ok ? 0 : 1
        }
        let response = await execute(commandArgs)
        write(response)
        return response.ok ? 0 : 1
    }

    static func execute(_ args: [String]) async -> AgentResponse {
        let service = AgentService()
        guard let command = args.first else {
            return .failure(command: "help", code: "MISSING_COMMAND", message: usage)
        }
        switch command {
        case "doctor": return await service.doctor()
        case "projects", "get-projects":
            return await service.projects(
                id: value("--id", in: args).flatMap(UUID.init(uuidString:)),
                offset: Int(value("--offset", in: args) ?? "0") ?? 0,
                limit: Int(value("--limit", in: args) ?? "20") ?? 20)
        case "edit-video", "edit-project":
            do {
                let request: AgentEditRequest
                if let jsonPath = value("--request", in: args) {
                    let data =
                        jsonPath == "-"
                        ? FileHandle.standardInput.readDataToEndOfFile()
                        : try Data(contentsOf: URL(fileURLWithPath: jsonPath))
                    request = try JSONDecoder().decode(AgentEditRequest.self, from: data)
                } else {
                    let sources = values("--input", in: args)
                    let profileName = value("--profile", in: args) ?? "clean-speech"
                    guard let profile = AgentEditProfile(rawValue: profileName) else {
                        throw AgentServiceError.invalidInput("Неизвестный профиль: \(profileName)")
                    }
                    request = AgentEditRequest(
                        sourcePaths: sources,
                        projectID: value("--project", in: args).flatMap(UUID.init(uuidString:)),
                        name: value("--name", in: args),
                        profile: profile,
                        removePauses: !args.contains("--keep-pauses"),
                        enhanceVoice: !args.contains("--raw-voice"),
                        musicPath: value("--music", in: args),
                        aiMode: args.contains("--external-ai")
                            ? .external
                            : (args.contains("--smart-edit") ? .builtIn : .off),
                        confirmModelDownload: args.contains("--confirm-model-download"))
                }
                return await service.edit(request)
            } catch {
                return .failure(command: command, code: "INVALID_REQUEST", message: error.localizedDescription)
            }
        case "job", "get-job":
            guard let id = value("--id", in: args).flatMap(UUID.init(uuidString:)) else {
                return .failure(command: "get_job", code: "INVALID_JOB_ID", message: "Укажите --id задачи.")
            }
            return await service.job(id: id)
        case "inspect":
            guard let id = value("--project", in: args).flatMap(UUID.init(uuidString:)) else {
                return .failure(command: "inspect", code: "INVALID_PROJECT_ID", message: "Укажите --project.")
            }
            return await service.inspect(projectID: id)
        case "export":
            guard let id = value("--project", in: args).flatMap(UUID.init(uuidString:)) else {
                return .failure(command: "export", code: "INVALID_PROJECT_ID", message: "Укажите --project.")
            }
            return await service.export(
                projectID: id, outputPath: value("--output", in: args),
                quality: value("--quality", in: args) ?? (args.contains("--final") ? "high" : "compact"),
                final: args.contains("--final"), confirmFinal: args.contains("--confirm-final"),
                overwrite: args.contains("--overwrite"))
        case "make-shorts":
            guard let input = value("--input", in: args) else {
                return .failure(command: "make_shorts", code: "MISSING_INPUT", message: "Укажите --input.")
            }
            return await service.makeShorts(
                sourcePath: input,
                confirmModelDownload: args.contains("--confirm-model-download"),
                trimPauses: !args.contains("--keep-pauses"))
        case "integration":
            do {
                let operation = args.dropFirst().first ?? "status"
                let status: AgentIntegrationStatus
                if operation == "install" {
                    status = try await AgentIntegrationInstaller.install()
                } else if operation == "uninstall" {
                    status = try await AgentIntegrationInstaller.uninstall()
                } else {
                    status = AgentIntegrationInstaller.status()
                }
                return .success(
                    command: "integration",
                    data: [
                        "installed": .bool(status.installed), "message": .string(status.message),
                    ])
            } catch {
                return .failure(command: "integration", code: "INTEGRATION_FAILED", message: error.localizedDescription)
            }
        default:
            return .failure(command: command, code: "UNKNOWN_COMMAND", message: usage)
        }
    }

    private static func value(_ flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    private static func values(_ flag: String, in args: [String]) -> [String] {
        args.indices.compactMap { args[$0] == flag && $0 + 1 < args.count ? args[$0 + 1] : nil }
    }

    private static func write(_ response: AgentResponse) {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(response) {
            FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }

    private static let usage =
        "Команды: doctor, projects, edit-video, edit-project, job, inspect, export, make-shorts, mcp serve."
}

private struct AgentMCPServer {
    private let service = AgentService()

    func run() async throws {
        let server = Server(
            name: "Montazhka", version: "1.0.0",
            instructions:
                "Локальный монтаж видео. Сначала вызовите montazhka_doctor. Финальный экспорт только после явного подтверждения пользователя.",
            capabilities: .init(resources: .init(), tools: .init()))
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(
                tools: AgentToolCatalog.definitions.map { definition in
                    Tool(
                        name: definition.name, description: definition.description,
                        inputSchema: .object(definition.inputSchema.mapValues(Self.mcpValue)),
                        annotations: .init(
                            readOnlyHint: definition.isReadOnly,
                            destructiveHint: definition.isDestructive,
                            idempotentHint: definition.isIdempotent,
                            openWorldHint: false))
                })
        }
        await server.withMethodHandler(CallTool.self) { request in
            let response = await call(name: request.name, arguments: request.arguments ?? [:])
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let text = (try? String(decoding: encoder.encode(response), as: UTF8.self)) ?? "{}"
            return CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], isError: !response.ok)
        }
        await server.withMethodHandler(ListResources.self) { _ in
            ListResources.Result(resources: [
                Resource(
                    name: "Справочник Монтажки", uri: "montazhka://guide",
                    description: "Контракт v1 и полный цикл монтажа", mimeType: "text/markdown")
            ])
        }
        await server.withMethodHandler(ReadResource.self) { request in
            do {
                let text: String
                if request.uri == "montazhka://guide" {
                    text = AgentDocumentation.guide
                } else {
                    text = try await service.resource(uri: request.uri)
                }
                return ReadResource.Result(contents: [.text(text, uri: request.uri, mimeType: "text/markdown")])
            } catch {
                return ReadResource.Result(contents: [.text(error.localizedDescription, uri: request.uri)])
            }
        }
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }

    private func call(name: String, arguments: [String: Value]) async -> AgentResponse {
        switch name {
        case "montazhka_doctor": return await service.doctor()
        case "montazhka_get_projects":
            return await service.projects(
                id: arguments["projectId"]?.stringValue.flatMap(UUID.init(uuidString:)),
                offset: arguments["offset"]?.intValue ?? 0, limit: arguments["limit"]?.intValue ?? 20)
        case "montazhka_edit_video", "montazhka_edit_project":
            do {
                let edit = try Self.editRequest(
                    arguments, requiresProject: name == "montazhka_edit_project")
                return try await AgentBackgroundJob.submit(.edit(edit))
            } catch {
                return .failure(command: name, code: "INVALID_REQUEST", message: error.localizedDescription)
            }
        case "montazhka_get_job":
            guard let id = arguments["jobId"]?.stringValue.flatMap(UUID.init(uuidString:)) else {
                return .failure(command: "get_job", code: "INVALID_JOB_ID", message: "Нужен jobId.")
            }
            return await service.job(id: id)
        case "montazhka_inspect":
            guard let id = arguments["projectId"]?.stringValue.flatMap(UUID.init(uuidString:)) else {
                return .failure(command: "inspect", code: "INVALID_PROJECT_ID", message: "Нужен projectId.")
            }
            return await service.inspect(
                projectID: id, around: arguments["cuts"]?.arrayValue?.compactMap(Self.double) ?? [])
        case "montazhka_export":
            guard let id = arguments["projectId"]?.stringValue.flatMap(UUID.init(uuidString:)) else {
                return .failure(command: "export", code: "INVALID_PROJECT_ID", message: "Нужен projectId.")
            }
            do {
                return try await AgentBackgroundJob.submit(
                    .export(
                        projectID: id, outputPath: arguments["outputPath"]?.stringValue,
                        quality: arguments["quality"]?.stringValue ?? "compact",
                        final: arguments["final"]?.boolValue ?? false,
                        confirmFinal: arguments["confirmFinal"]?.boolValue ?? false,
                        overwrite: arguments["overwrite"]?.boolValue ?? false))
            } catch {
                return .failure(command: "export", code: "JOB_START_FAILED", message: error.localizedDescription)
            }
        case "montazhka_make_shorts":
            guard let path = arguments["sourcePath"]?.stringValue else {
                return .failure(command: "make_shorts", code: "MISSING_INPUT", message: "Нужен sourcePath.")
            }
            do {
                return try await AgentBackgroundJob.submit(
                    .shorts(
                        sourcePath: path,
                        confirmModelDownload: arguments["confirmModelDownload"]?.boolValue ?? false,
                        trimPauses: arguments["trimPauses"]?.boolValue ?? true))
            } catch {
                return .failure(command: "make_shorts", code: "JOB_START_FAILED", message: error.localizedDescription)
            }
        default: return .failure(command: name, code: "UNKNOWN_TOOL", message: "Неизвестный инструмент.")
        }
    }

    private static func double(_ value: Value?) -> Double? {
        value?.doubleValue ?? value?.intValue.map(Double.init)
    }

    private static func editRequest(
        _ arguments: [String: Value], requiresProject: Bool
    ) throws -> AgentEditRequest {
        let sources: [String]
        if let value = arguments["sourcePaths"] {
            guard let items = value.arrayValue, items.allSatisfy({ $0.stringValue != nil }) else {
                throw AgentServiceError.invalidInput("sourcePaths должен содержать только пути к файлам.")
            }
            sources = items.compactMap(\.stringValue)
        } else {
            sources = []
        }
        let projectID = arguments["projectId"]?.stringValue.flatMap(UUID.init(uuidString:))
        if requiresProject, projectID == nil {
            throw AgentServiceError.invalidInput("Нужен корректный projectId.")
        }
        if !requiresProject, sources.isEmpty {
            throw AgentServiceError.invalidInput("Нужен хотя бы один sourcePath.")
        }
        let profileName = arguments["profile"]?.stringValue ?? "clean-speech"
        guard let profile = AgentEditProfile(rawValue: profileName) else {
            throw AgentServiceError.invalidInput("Неизвестный профиль: \(profileName)")
        }
        let cuts = try (arguments["cuts"]?.arrayValue ?? []).map { value -> AgentSourceCut in
            guard let item = value.objectValue, let path = item["sourcePath"]?.stringValue,
                let start = double(item["start"]), let end = double(item["end"])
            else {
                throw AgentServiceError.invalidInput("Каждый рез должен содержать sourcePath, start и end.")
            }
            return AgentSourceCut(sourcePath: path, start: start, end: end)
        }
        let aiModeName = arguments["aiMode"]?.stringValue ?? "off"
        guard let aiMode = AgentAIMode(rawValue: aiModeName) else {
            throw AgentServiceError.invalidInput("Неизвестный режим ИИ: \(aiModeName)")
        }
        return AgentEditRequest(
            sourcePaths: sources, projectID: projectID,
            name: arguments["name"]?.stringValue, profile: profile, cuts: cuts,
            removePauses: arguments["removePauses"]?.boolValue ?? true,
            enhanceVoice: arguments["enhanceVoice"]?.boolValue ?? true,
            musicPath: arguments["musicPath"]?.stringValue,
            aiMode: aiMode,
            confirmModelDownload: arguments["confirmModelDownload"]?.boolValue ?? false)
    }

    private static func mcpValue(_ value: AgentJSONValue) -> Value {
        switch value {
        case .string(let value): .string(value)
        case .bool(let value): .bool(value)
        case .number(let value): .double(value)
        case .object(let value): .object(value.mapValues(mcpValue))
        case .array(let value): .array(value.map(mcpValue))
        case .null: .null
        }
    }
}

enum AgentDocumentation {
    static let guide = """
        # Монтажка Agent API v1
        Начните с `montazhka_doctor`, затем выберите проект или передайте `sourcePaths`.
        `clean-speech` бережно убирает длинные паузы, улучшает голос и не включает музыку.
        `dynamic` делает паузы короче. `shorts` готовит пять роликов 9:16 с субтитрами.
        `aiMode=built-in` использует настройки ИИ приложения; `aiMode=external` отдаёт расшифровку агенту.
        Долгие операции возвращают `jobId`; состояние читает `montazhka_get_job`.
        Большие материалы доступны через `montazhka://runs/{jobId}/{artifact}`.
        Всегда проверьте файлы, длительность, дорожки, резы, склейки и черновой MP4.
        Финальный экспорт требует `final=true` и `confirmFinal=true` после явного «ОК» пользователя.
        Исходные видео не перезаписываются; существующий результат требует `overwrite=true`.
        """

    static let skill = """
        ---
        name: montazhka
        description: Управляет локальным видеомонтажом через компактный MCP Монтажки.
        ---
        # Монтажка
        Сначала вызови `montazhka_doctor`. Для длинных данных читай `montazhka://` ресурс только при необходимости.
        Для обычной речи используй профиль `clean-speech`, для энергичного ролика — `dynamic`, для вертикальных клипов — `shorts`.
        Всегда проверь доступность файлов, длительность, дорожки, резы, склейки и черновой MP4.
        Финальный экспорт запускай только после явного «ОК» пользователя.
        Исходники не перезаписывай. Подробный контракт доступен в ресурсе `montazhka://guide`.
        """
}
