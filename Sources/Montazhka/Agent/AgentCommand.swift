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
                overwrite: args.contains("--overwrite"),
                normalizeLoudness: args.contains("--no-normalize-loudness") ? false : nil,
                burnSubtitles: args.contains("--burn-subtitles") ? true : nil)
        case "check":
            guard let id = value("--project", in: args).flatMap(UUID.init(uuidString:)) else {
                return .failure(command: "check", code: "INVALID_PROJECT_ID", message: "Укажите --project.")
            }
            return await service.check(
                AgentCheckRequest(
                    projectID: id, filePath: value("--file", in: args), from: number("--from", in: args),
                    to: number("--to", in: args), window: number("--window", in: args),
                    words: !args.contains("--no-words"),
                    confirmModelDownload: args.contains("--confirm-model-download")))
        case "critic-prompt":
            return .success(command: "critic_prompt", data: ["text": .string(AgentDocumentation.critic)])
        case "make-shorts":
            guard let path = value("--request", in: args) else {
                return .failure(
                    command: "make_shorts", code: "MISSING_INPUT",
                    message: "Укажите --request <файл JSON>: {projectId, timeline, shorts: [...]}.")
            }
            do {
                let request = try JSONDecoder().decode(
                    AgentShortsRequest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
                return await service.makeShorts(request)
            } catch {
                return .failure(command: "make_shorts", code: "INVALID_REQUEST", message: error.localizedDescription)
            }
        case "transcript":
            return await service.transcriptOrStartJob(
                AgentTranscriptRequest(
                    target: target(args), from: number("--from", in: args), to: number("--to", in: args),
                    query: value("--query", in: args), phrases: args.contains("--phrases"),
                    retakes: args.contains("--retakes"),
                    confirmModelDownload: args.contains("--confirm-model-download")))
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

    /// Запрос фонового экспорта из аргументов MCP. `normalizeLoudness`/`burnSubtitles`
    /// не переданы — nil: как в настройках экспорта проекта.
    static func mcpExportRequest(projectID: UUID, arguments: [String: AgentJSONValue]) -> AgentWorkerRequest {
        func flag(_ key: String) -> Bool? {
            if case .bool(let value)? = arguments[key] { value } else { nil }
        }
        func text(_ key: String) -> String? {
            if case .string(let value)? = arguments[key] { value } else { nil }
        }
        return .export(
            projectID: projectID, outputPath: text("outputPath"), quality: text("quality") ?? "compact",
            final: flag("final") ?? false, confirmFinal: flag("confirmFinal") ?? false,
            overwrite: flag("overwrite") ?? false, normalizeLoudness: flag("normalizeLoudness"),
            burnSubtitles: flag("burnSubtitles"))
    }

    private static let usage =
        "Команды: doctor, projects, edit-video, edit-project, job, inspect, transcript, frames, audio, "
        + "apply-edits, export, check, critic-prompt, make-shorts, mcp serve."
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
            ListResources.Result(
                resources: AgentDocumentation.resources.map {
                    Resource(name: $0.name, uri: $0.uri, description: $0.description, mimeType: "text/markdown")
                })
        }
        await server.withMethodHandler(ReadResource.self) { request in
            do {
                let text: String
                if let documentation = AgentDocumentation.resourceText(uri: request.uri) {
                    text = documentation
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
                let values = try JSONDecoder().decode(
                    [String: AgentJSONValue].self, from: JSONEncoder().encode(arguments))
                return try await AgentBackgroundJob.submit(
                    AgentCommand.mcpExportRequest(projectID: id, arguments: values))
            } catch {
                return .failure(command: "export", code: "JOB_START_FAILED", message: error.localizedDescription)
            }
        case "montazhka_make_shorts":
            let request: AgentShortsRequest
            do {
                request = try JSONDecoder().decode(AgentShortsRequest.self, from: JSONEncoder().encode(arguments))
            } catch {
                return .failure(
                    command: "make_shorts", code: "INVALID_REQUEST",
                    message: "Не удалось разобрать запрос: \(error.localizedDescription)",
                    recovery:
                        "Нужны projectId, timeline из montazhka_transcript и shorts: [{title, pieces: [{from, to}]}].")
            }
            // Пустой список не запускает фоновую задачу: сразу объясняем, что делать.
            guard !request.shorts.isEmpty else { return await service.makeShorts(request) }
            do {
                return try await AgentBackgroundJob.submit(.shorts(request))
            } catch {
                return .failure(command: "make_shorts", code: "JOB_START_FAILED", message: error.localizedDescription)
            }
        case "montazhka_transcript":
            return await service.transcriptOrStartJob(
                AgentTranscriptRequest(
                    target: Self.target(arguments), from: Self.double(arguments["from"]),
                    to: Self.double(arguments["to"]), query: arguments["query"]?.stringValue,
                    phrases: arguments["phrases"]?.boolValue ?? false,
                    retakes: arguments["retakes"]?.boolValue ?? false,
                    confirmModelDownload: arguments["confirmModelDownload"]?.boolValue ?? false))
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
        case "montazhka_check":
            guard let id = arguments["projectId"]?.stringValue.flatMap(UUID.init(uuidString:)) else {
                return .failure(command: "check", code: "INVALID_PROJECT_ID", message: "Нужен projectId.")
            }
            return await service.check(
                AgentCheckRequest(
                    projectID: id, filePath: arguments["filePath"]?.stringValue, from: Self.double(arguments["from"]),
                    to: Self.double(arguments["to"]), window: Self.double(arguments["window"]),
                    words: arguments["words"]?.boolValue ?? true,
                    confirmModelDownload: arguments["confirmModelDownload"]?.boolValue ?? false))
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
    /// Постоянные текстовые ресурсы MCP; остальные адреса — материалы фоновых задач.
    static let resources: [(uri: String, name: String, description: String)] = [
        ("montazhka://guide", "Справочник Монтажки", "Контракт v1 и полный цикл монтажа"),
        ("montazhka://critic", "Критик Монтажки", "Промпт строгого критика готового ролика для отдельного субагента"),
    ]

    static func resourceText(uri: String) -> String? {
        switch uri {
        case "montazhka://guide": guide
        case "montazhka://critic": critic
        default: nil
        }
    }

    /// Промпт критика. Подставьте {{filePath}}, {{projectId}}, {{brief}} (бриф пользователя дословно)
    /// и {{notes}} (заметки проекта) и отдайте субагенту со свежим контекстом.
    static let critic = """
        Ты — строгий редактор видеомонтажа. Твоя задача — найти проблемы в готовом ролике, а не хвалить его.
        Похвала запрещена. Молчание о проблеме — провал задания.
        Вход: файл {{filePath}}, проект {{projectId}}. Бриф пользователя: {{brief}}. Заметки монтажа: {{notes}}.
        Инструменты Монтажки — только для чтения: montazhka_check (склейки готового файла), montazhka_frames и
        montazhka_audio с filePath, montazhka_transcript (projectId или filePath), montazhka_inspect. Ничего не
        правь и не экспортируй.
        Порядок: 1) montazhka_check и разбор каждой проблемы из problems; 2) montazhka_transcript готового файла
        целиком — повторяй вызов с nextFrom, пока он не станет null: оборванные мысли, повторы и дубли,
        оговорки, слова-паразиты, логика и порядок; 3) montazhka_frames: начало (цепляет ли первые 3 секунды),
        конец (завершена ли мысль), подозрительные места; 4) сверка с брифом: сделано ли то, что просили, и не
        вырезано ли важное.
        Каждая проблема: время (мм:сс.д), тип technical или taste, серьёзность critical/major/minor, улика
        (цитата слов, цифра из check, описание кадра), предлагаемая правка. Без улики проблему не пиши.
        Ответ строго в формате:
        VERDICT: ship | fix | rework — одна фраза почему.
        ISSUES: нумерованный список, от самой серьёзной.
        TOP-5 FIXES: пять самых ценных правок, конкретно (что, где, чем).
        technical — объективный дефект: обрезанное слово, щелчок, провал звука, чёрный или застывший кадр,
        скачок громкости. taste — темп, выбор дубля, порядок, хук, музыка. Не выдумывай проблем без улик.
        """

    static let guide = """
        # Монтажка Agent API v1
        Начните с `montazhka_doctor`, затем выберите проект или передайте `sourcePaths`.
        `clean-speech` бережно убирает длинные паузы, улучшает голос и не включает музыку.
        `dynamic` делает паузы короче. Вертикальные шортсы — раздел «Шортсы и Reels» ниже.
        `aiMode=built-in` использует настройки ИИ приложения; `aiMode=external` отдаёт расшифровку агенту.
        Долгие операции возвращают `jobId`; ждите их `montazhka_get_job waitSeconds=25` — вызов
        сам дождётся смены этапа. Большие материалы — `montazhka://runs/{jobId}/{artifact}`.
        Поле `warnings` в ответе читайте всегда: там, например, просьба перезапустить сессию.

        ## Заметки проекта
        Пользователь их не видит. В начале работы прочитайте `notes` в `montazhka_inspect`; в конце сессии
        допишите `{"op":"note","text":"…"}` (`montazhka_apply_edits`): бриф пользователя, стратегия, решения,
        просьбы, что осталось. `setNotes` переписывает целиком, когда пора сжать (лимит 20 000 знаков).
        `undo` заметки не откатывает, копия проекта получает их копию.

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
           `montazhka_export final=true confirmFinal=true quality=high`. Экспорт сам приводит звук к −14 LUFS
           (`normalizeLoudness=false` — выключить); смотрите `loudness` в итоге. Рядом с MP4 всегда ложится `.srt`;
           вшить субтитры — `burnSubtitles=true` или `setSubtitles{on}`.
        7. Проверьте результат: `durationCheck.matches` в итоге задачи, затем `montazhka_frames`
           и `montazhka_audio` с `filePath` готового MP4 (`audio` с `filePath` даёт и `loudness`).
        8. `montazhka_check projectId filePath` — каждая склейка готового файла: `problems` с уликами (обрезанное
           слово, щелчок, провал звука, чёрный кадр, скачок громкости), `loudness` и сетка кадров у склеек.
           Больше 40 склеек — повторите с `from=nextFrom`; `wordsCheck.status=pending` — дождитесь `jobId` и
           вызовите снова. Сервер без `montazhka_check` (старая версия) —
           `montazhka_frames projectId filePath aroundCuts=true`. Затем — критик (раздел ниже).
        Говорящая голова: режьте по словам (оговорки, повторы, дубли — оставляйте последний удачный).
        Запись экрана: ищите по кадрам участки, где картинка не меняется, и сокращайте их.

        Термины, которые распознавание пишет по-русски («клод код», «чат ГПТ»), исправляет словарь.
        Остальные ошибки чините `{"op":"fixWords","words":[{"from":12,"to":13}],"timeline":"…","text":"Cursor",
        "remember":true}`: номера слов не сдвигаются, `remember` запоминает замену навсегда.

        ## Критик перед сдачей
        После финального экспорта и своего `montazhka_check` запустите критика отдельным субагентом со свежим
        контекстом (в Claude Code — субагент; в Codex — отдельная сессия `codex exec`, если субагент не видит MCP).
        Промпт — ресурс `montazhka://critic`: подставьте путь MP4, projectId, бриф пользователя дословно и заметки.
        Технические проблемы чините сами, перевыгружайте (`overwrite=true`) и зовите нового критика; вердикт
        `ship` или 3 круга — конец. Вкусовые замечания не чините молча — покажите пользователю списком вместе
        с путём к файлу.

        ## Анимации поверх видео
        Только обычный проект. 1) Найдите в `montazhka_transcript` слово, на которое приходится кульминация
        (payoff); `frameSize` — в `montazhka_inspect`. 2) Композиция HyperFrames этого размера с прозрачным
        корнем, 2–6 с; запомните секунду кульминации. 3) `npx hyperframes render --format mov --fps 30` (60, если
        видео 60 к/с) — webm не поддерживается. 4) `{"op":"addOverlay","file":"….mov","words":[{"from":N,"to":N}],
        "timeline":"…","align":"payoff","payoffAt":1.2}` — секунда 1.2 анимации совпадёт с началом слова #N;
        `align:"start"` — анимация начнётся со слова; `at` (секунды ленты) вместо words. 5) Проверьте
        `montazhka_frames` в её окне. `position`: `full` — вписана в кадр целиком (`scale` не нужен); `center`
        и углы `topLeft`, `topRight`, `bottomLeft`, `bottomRight` — уменьшена в `scale` (0.2…1), отступ 4% от
        краёв. Анимация держится за слово: правки ленты двигают её вместе с ним, вырезанное слово скрывает её
        (предупреждение в `warnings`). `removeOverlay{overlay:id}`, `clearOverlays`; окна на ленте и статус —
        `overlays` в inspect. Несколько анимаций — параллельные субагенты, у каждого своя папка и файл;
        добавляйте их после всех рендеров.

        ## Дубли
        `montazhka_transcript retakes=true` находит соседние похожие фразы: `restart` — оборванное начало,
        `repeat` — фраза сказана заново. Это кандидаты; какой дубль оставить, решаете вы: обычно последний целый,
        без запинок; сомневаетесь — послушайте `montazhka_audio` и посмотрите `frames`. Лишние дубли режьте одним
        `deleteWords`: `from`/`to` дубля — номера слов. `phrases=true` показывает расшифровку фразами
        `¶номер #первое–#последнее начало конец текст`. Дубли в разных файлах:
        `edit_video sourcePaths=[…] removePauses=false` или `transcript filePath=` + `insert`.

        ## Шортсы и Reels
        Моменты выбираете вы сами — встроенный платный отбор не вызывается.
        1. Исходник только файлом → `montazhka_edit_video removePauses=false enhanceVoice=false`, это проект.
        2. `montazhka_transcript` целиком (страницы через `nextFrom`). Сначала исправьте термины `fixWords`.
        3. Кандидаты. Каждый оцените 0–10: hook — цепляет ли первая фраза за 3 секунды (вопрос, спор, цифра,
           обещание, конфликт); standalone — понятен без остального видео; payoff — есть награда (инсайт,
           совет, история с выводом, эмоция); pacing — без воды. Любой ниже 4 — не берите. Сильные паттерны:
           неожиданное мнение, история с конфликтом, список или цифры, разбор ошибки, миф, практический совет.
           Никогда: приветствия, реклама, «как я уже говорил», вопрос без ответа, обрыв мысли.
           Старт — ровно с сильной фразы, конец — на завершённой мысли; 20–45 с (допустимо 12–60).
           Можно склеить несколько несмежных кусков, если мысль цельная. Не больше двух роликов на одну тему.
           Последний фильтр — тест холодного зрителя: поймёт ли он первые 3 секунды и досмотрит ли до конца.
           Сколько роликов — сколько нашлось сильных (обычно 3–7), или сколько попросил пользователь.
        4. СТОП: покажите пользователю таблицу — №, заголовок, текст хука, первые и последние слова,
           длительность, почему момент сильный — и спросите, нужны ли субтитры. Монтируйте только выбранное.
        5. Раскладка: посмотрите `montazhka_frames` исходника. Голова в камеру → `face` (кадр ведёт лицо);
           запись экрана с лицом в углу → `split` (экран целиком сверху, лицо снизу); лица нет → `fit`;
           сомневаетесь → `auto`. Хук — до 7 слов, не повторяет первую фразу, без обмана; он висит первые 2,5 с.
           Наезды плавные: 1–3 на ролик по 2–6 с на ключевых фразах (`zooms` словами) или не передавайте — подберутся
           сами. Музыка: `mood` по тону (calm, neutral, energetic, inspiring, playful, tense, emotional) или id
           трека из `montazhka_doctor.music`; она сама стихает под голосом.
        6. `montazhka_make_shorts {projectId, timeline, shorts:[{title, hook, subtitles, pieces:[{from,to}],
           layout, zooms, mood}]}` → `jobId`. Каждый ролик — черновик-проект и MP4 в папке «<исходник>-shorts».
           Паузы и «эээ» (строки «звук без слов» в расшифровке) вырезаются сами; повторы и оговорки внутри
           кусков уберите потом `deleteWords` в черновике.
        7. Самопроверка каждого черновика: `montazhka_frames projectId` — вертикальный кадр как в MP4 (лицо
           в кадре, хук читается, субтитры не перекрыты), `aroundCuts=true`, `montazhka_audio`. Правки
           черновика — `apply_edits`: deleteWords, setHook{text}, setLayout{layout}, setSubtitles{on},
           zoom{words,timeline}, clearZooms, setMusic{track,volume}; затем `montazhka_export projectId` —
           файл черновика перезапишется. Текущее оформление (хук, раскладка, наезды во времени ленты, музыка,
           путь MP4) — блок `shorts` в `montazhka_inspect` и в ответе `apply_edits`.
        8. Отчёт пользователю: ролики, пути к MP4, длительности, что вырезано и почему.

        Исходные видео не перезаписываются; существующий результат требует `overwrite=true`.
        """

    static let skill = """
        ---
        name: montazhka
        description: Самостоятельный локальный видеомонтаж через MCP Монтажки — смотреть кадры, слушать громкость, читать расшифровку, резать, переставлять и отдавать готовый MP4.
        ---
        # Монтажка
        Сначала вызови `montazhka_doctor` и прочитай ресурс `montazhka://guide` — там полный порядок монтажа.
        В начале работы с проектом прочитай его заметки (`notes` в `montazhka_inspect`), в конце сессии допиши
        бриф, решения и что осталось операцией `note` в `montazhka_apply_edits`.
        Дубли ищи через `montazhka_transcript retakes=true` — это кандидаты, какой дубль оставить, решаешь сам.
        Для обычной речи используй профиль `clean-speech`, для энергичного ролика — `dynamic`.
        Шортсы и Reels: моменты выбираешь сам по расшифровке, показываешь пользователю список и спрашиваешь про
        субтитры, потом `montazhka_make_shorts` — порядок в разделе «Шортсы и Reels» гайда.
        Решения о резах принимай по расшифровке (`montazhka_transcript`, поиск фразы — `query`), слова режь
        по номерам операцией `deleteWords`, сомнительные места проверяй кадрами (`montazhka_frames`)
        и громкостью (`montazhka_audio`), правь через `montazhka_apply_edits`. Читай `warnings` в ответах.
        После правок посмотри кадры у склеек. Если пользователь поручил готовый файл — делай финальный
        экспорт сам и проверь готовый MP4 теми же инструментами и `montazhka_check`. Исходники не перезаписывай.
        Перед сдачей запусти критика отдельным субагентом — промпт в ресурсе `montazhka://critic`.
        """
}
