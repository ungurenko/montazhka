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
            return await service.job(id: id, waitSeconds: number("--wait", in: args) ?? 0)
        case "inspect":
            guard let id = value("--project", in: args).flatMap(UUID.init(uuidString:)) else {
                return .failure(command: "inspect", code: "INVALID_PROJECT_ID", message: "Укажите --project.")
            }
            return await service.inspect(
                projectID: id, offset: value("--offset", in: args).flatMap(Int.init) ?? 0,
                limit: value("--limit", in: args).flatMap(Int.init) ?? 200)
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
        case "transcript":
            guard let id = value("--project", in: args).flatMap(UUID.init(uuidString:)) else {
                return .failure(command: "transcript", code: "INVALID_PROJECT_ID", message: "Укажите --project.")
            }
            return await service.transcriptOrStartJob(
                projectID: id, from: number("--from", in: args), to: number("--to", in: args),
                query: value("--query", in: args),
                confirmModelDownload: args.contains("--confirm-model-download"))
        case "frames":
            return await service.frames(
                AgentFramesRequest(
                    target: target(args), from: number("--from", in: args), to: number("--to", in: args),
                    count: value("--count", in: args).flatMap(Int.init),
                    times: (value("--times", in: args) ?? "").split(separator: ",").compactMap {
                        Double($0.trimmingCharacters(in: .whitespaces))
                    },
                    aroundCuts: args.contains("--around-cuts")))
        case "audio":
            return await service.audio(
                target: target(args), from: number("--from", in: args), to: number("--to", in: args),
                buckets: value("--buckets", in: args).flatMap(Int.init))
        case "apply-edits":
            guard let id = value("--project", in: args).flatMap(UUID.init(uuidString:)) else {
                return .failure(command: "apply_edits", code: "INVALID_PROJECT_ID", message: "Укажите --project.")
            }
            do {
                let operations: [AgentEditOperation]
                if args.contains("--undo") {
                    operations = [AgentEditOperation(op: "undo", steps: value("--undo", in: args).flatMap(Int.init))]
                } else {
                    guard let path = value("--request", in: args) else {
                        throw AgentServiceError.invalidInput("Укажите --request <файл|-> с operations или --undo.")
                    }
                    let data =
                        path == "-"
                        ? FileHandle.standardInput.readDataToEndOfFile()
                        : try Data(contentsOf: URL(fileURLWithPath: path))
                    operations = try AgentEditOperation.decodeList(data)
                }
                return await service.applyEdits(projectID: id, operations: operations)
            } catch {
                return .failure(command: "apply_edits", code: "INVALID_REQUEST", message: error.localizedDescription)
            }
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

    private static func number(_ flag: String, in args: [String]) -> Double? {
        value(flag, in: args).flatMap(Double.init)
    }

    private static func target(_ args: [String]) -> AgentMediaTarget {
        AgentMediaTarget(
            projectID: value("--project", in: args).flatMap(UUID.init(uuidString:)),
            filePath: value("--file", in: args))
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
        "Команды: doctor, projects, edit-video, edit-project, job, inspect, transcript, frames, audio, "
        + "apply-edits, export, make-shorts, mcp serve."
}

private struct AgentMCPServer {
    private let service = AgentService()
    private let startedStamp = AgentBuildInfo.executableStamp()

    /// Приложение переустановили, пока сервер работал.
    private var isStale: Bool {
        AgentBuildInfo.executableStamp() != startedStamp
    }

    func run() async throws {
        let server = Server(
            name: "Montazhka", version: AgentBuildInfo.version,
            instructions:
                "Локальный монтаж видео. Сначала вызовите montazhka_doctor и прочитайте montazhka://guide. "
                + "Финальный экспорт — когда пользователь поручил сделать готовый файл.",
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
            var response = await call(name: request.name, arguments: request.arguments ?? [:])
            let stale = isStale
            if request.name == "montazhka_doctor", response.data != nil {
                response.data?["serverStale"] = .bool(stale)
            }
            if stale { response = response.addingWarning(AgentBuildInfo.staleWarning) }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let text = (try? String(decoding: encoder.encode(response), as: UTF8.self)) ?? "{}"
            var content: [Tool.Content] = [.text(text: text, annotations: nil, _meta: nil)]
            if case .string(let path)? = response.data?["imagePath"],
                let image = FileManager.default.contents(atPath: path)
            {
                content.append(
                    .image(data: image.base64EncodedString(), mimeType: "image/jpeg", annotations: nil, _meta: nil))
            }
            return CallTool.Result(content: content, isError: !response.ok)
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
            return await service.job(id: id, waitSeconds: Self.double(arguments["waitSeconds"]) ?? 0)
        case "montazhka_inspect":
            guard let id = arguments["projectId"]?.stringValue.flatMap(UUID.init(uuidString:)) else {
                return .failure(command: "inspect", code: "INVALID_PROJECT_ID", message: "Нужен projectId.")
            }
            return await service.inspect(
                projectID: id, around: arguments["cuts"]?.arrayValue?.compactMap(Self.double) ?? [],
                offset: arguments["offset"]?.intValue ?? 0, limit: arguments["limit"]?.intValue ?? 200)
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
        case "montazhka_transcript":
            guard let id = arguments["projectId"]?.stringValue.flatMap(UUID.init(uuidString:)) else {
                return .failure(command: "transcript", code: "INVALID_PROJECT_ID", message: "Нужен projectId.")
            }
            return await service.transcriptOrStartJob(
                projectID: id, from: Self.double(arguments["from"]), to: Self.double(arguments["to"]),
                query: arguments["query"]?.stringValue,
                confirmModelDownload: arguments["confirmModelDownload"]?.boolValue ?? false)
        case "montazhka_frames":
            return await service.frames(
                AgentFramesRequest(
                    target: Self.target(arguments), from: Self.double(arguments["from"]),
                    to: Self.double(arguments["to"]), count: arguments["count"]?.intValue,
                    times: arguments["times"]?.arrayValue?.compactMap(Self.double) ?? [],
                    aroundCuts: arguments["aroundCuts"]?.boolValue ?? false))
        case "montazhka_audio":
            return await service.audio(
                target: Self.target(arguments), from: Self.double(arguments["from"]),
                to: Self.double(arguments["to"]), buckets: arguments["buckets"]?.intValue)
        case "montazhka_apply_edits":
            guard let id = arguments["projectId"]?.stringValue.flatMap(UUID.init(uuidString:)) else {
                return .failure(command: "apply_edits", code: "INVALID_PROJECT_ID", message: "Нужен projectId.")
            }
            do {
                let data = try JSONEncoder().encode(arguments["operations"] ?? .array([]))
                return await service.applyEdits(projectID: id, operations: try AgentEditOperation.decodeList(data))
            } catch {
                return .failure(command: "apply_edits", code: "INVALID_REQUEST", message: error.localizedDescription)
            }
        default: return .failure(command: name, code: "UNKNOWN_TOOL", message: "Неизвестный инструмент.")
        }
    }

    private static func target(_ arguments: [String: Value]) -> AgentMediaTarget {
        AgentMediaTarget(
            projectID: arguments["projectId"]?.stringValue.flatMap(UUID.init(uuidString:)),
            filePath: arguments["filePath"]?.stringValue)
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
        Долгие операции возвращают `jobId`; ждите их `montazhka_get_job waitSeconds=25` — вызов
        сам дождётся смены этапа. Большие материалы — `montazhka://runs/{jobId}/{artifact}`.
        Поле `warnings` в ответе читайте всегда: там, например, просьба перезапустить сессию.

        ## Самостоятельный монтаж
        Все инструменты ниже работают во времени ленты проекта (секунды итогового ролика).
        1. `montazhka_edit_video` (паузы убраны) → `montazhka_inspect`: клипы с номерами и временем
           (до 200 за вызов, дальше `offset=nextOffset`).
        2. `montazhka_transcript`: строки `#номер начало конец слово`, отметки пауз и склеек,
           отпечаток ленты `timeline`. `query="фраза"` находит, где она звучит. Если расшифровки нет,
           вызов запускает её в фоне и возвращает `jobId` — дождитесь его и вызовите снова.
        3. `montazhka_frames`: сетка кадров картинкой. Узкий `from/to` — приближение к моменту.
           `montazhka_audio`: громкость по отрезкам и тишины.
        4. Слова режьте по номерам: `{"op":"deleteWords","words":[{"from":120,"to":135}],"timeline":"…"}` —
           все диапазоны в одном deleteWords, номера и timeline из последнего transcript; рез ляжет
           в тишину между словами. После любой правки номера слов и клипов меняются: для следующего
           deleteWords заново вызовите transcript. Остальное — `montazhka_apply_edits` по времени ленты:
           delete, split, move, trim, insert (кусок другого исходника). Операции идут по порядку, каждая
           видит ленту после предыдущей; диапазоны одного delete считаются по ленте до него. Ответ
           предупреждает о резах посреди слова и обрывках короче 0,25 с. Ошибка — `{"op":"undo"}`
           отдельным вызовом.
        5. После правок: `montazhka_frames aroundCuts=true` (скачки картинки) и `montazhka_audio` у склеек.
        6. Если пользователь поручил сделать готовый файл, это согласие на финал:
           `montazhka_export final=true confirmFinal=true quality=high`.
        7. Проверьте результат: `durationCheck.matches` в итоге задачи, затем `montazhka_frames`
           и `montazhka_audio` с `filePath` готового MP4.
        Говорящая голова: режьте по словам (оговорки, повторы, дубли — оставляйте последний удачный).
        Запись экрана: ищите по кадрам участки, где картинка не меняется, и сокращайте их.

        Исходные видео не перезаписываются; существующий результат требует `overwrite=true`.
        """

    static let skill = """
        ---
        name: montazhka
        description: Самостоятельный локальный видеомонтаж через MCP Монтажки — смотреть кадры, слушать громкость, читать расшифровку, резать, переставлять и отдавать готовый MP4.
        ---
        # Монтажка
        Сначала вызови `montazhka_doctor` и прочитай ресурс `montazhka://guide` — там полный порядок монтажа.
        Для обычной речи используй профиль `clean-speech`, для энергичного ролика — `dynamic`, для вертикальных клипов — `shorts`.
        Решения о резах принимай по расшифровке (`montazhka_transcript`, поиск фразы — `query`), слова режь
        по номерам операцией `deleteWords`, сомнительные места проверяй кадрами (`montazhka_frames`)
        и громкостью (`montazhka_audio`), правь через `montazhka_apply_edits`. Читай `warnings` в ответах.
        После правок посмотри кадры у склеек. Если пользователь поручил готовый файл — делай финальный
        экспорт сам и проверь готовый MP4 теми же инструментами. Исходники не перезаписывай.
        """
}
