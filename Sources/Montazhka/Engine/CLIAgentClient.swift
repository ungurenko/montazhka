import Foundation

protocol AICompletionServing: Sendable {
    func complete(
        system: String,
        user: String,
        configuration: AIRequestConfiguration
    ) async throws -> String
}

actor CLIAgentClient: AICompletionServing {
    static let disabledCodexFeatures = [
        "shell_tool",
        "unified_exec",
        "apps",
        "plugins",
        "browser_use",
        "computer_use",
        "image_generation",
        "multi_agent",
        "skill_search",
        "code_mode_host",
    ]

    func complete(
        system: String,
        user: String,
        configuration: AIRequestConfiguration
    ) async throws -> String {
        let prompt = """
            Ты работаешь как внутренний JSON-сервис приложения «Монтажка».
            Не используй инструменты, не читай файлы и не выполняй команды.
            Верни только итоговый JSON без Markdown, пояснений и служебного текста.

            <system_instructions>
            \(system)
            </system_instructions>

            <user_request>
            \(user)
            </user_request>
            """
        switch configuration {
        case .codexCLI(let model, let effort, let executable):
            return try await runCodex(
                executable: executable,
                prompt: prompt,
                model: model,
                effort: effort)
        case .openCodeCLI(let model, let effort, let executable):
            return try await runOpenCode(
                executable: executable,
                prompt: prompt,
                model: model,
                effort: effort)
        case .openRouter:
            throw AIProviderError.agentUnavailable("OpenRouter")
        }
    }

    private func runCodex(
        executable: URL,
        prompt: String,
        model: String,
        effort: String?
    ) async throws -> String {
        let directory = try makeWorkingDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("answer.json")
        var arguments = [
            "exec", "--ignore-user-config", "--strict-config",
        ]
        arguments += Self.disabledCodexFeatures.flatMap { ["--disable", $0] }
        arguments += [
            "--ephemeral", "--skip-git-repo-check",
            "--sandbox", "read-only", "--color", "never",
            "--cd", directory.path, "--model", model,
        ]
        if let effort { arguments += ["--config", "model_reasoning_effort=\"\(effort)\""] }
        arguments += ["--output-last-message", outputURL.path, "-"]
        let result: LocalProcessResult
        do {
            result = try await LocalProcessRunner.run(
                executable: executable,
                arguments: arguments,
                input: Data(prompt.utf8),
                currentDirectory: directory)
        } catch is CancellationError {
            throw CancellationError()
        } catch AIProviderError.timeout {
            throw AIProviderError.timeout("Codex CLI")
        } catch {
            throw AIProviderError.commandFailed("Codex CLI")
        }
        guard result.exitCode == 0 else { throw AIProviderError.commandFailed("Codex CLI") }
        guard let answer = try? String(contentsOf: outputURL, encoding: .utf8),
            !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw AIProviderError.emptyResponse("Codex CLI") }
        return answer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runOpenCode(
        executable: URL,
        prompt: String,
        model: String,
        effort: String?
    ) async throws -> String {
        let directory = try makeWorkingDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let promptURL = directory.appendingPathComponent("request.txt")
        let configURL = directory.appendingPathComponent("opencode.json")
        try prompt.write(to: promptURL, atomically: true, encoding: .utf8)
        let config = OpenCodeIsolationConfiguration()
        try JSONEncoder().encode(config).write(to: configURL, options: .atomic)
        var arguments = [
            "run", "--pure", "--format", "json", "--model", model,
            "--dir", directory.path, "--file", promptURL.path,
        ]
        if let effort { arguments += ["--variant", effort] }
        arguments.append("--")
        arguments.append("Обработай приложенный запрос и верни только требуемый JSON.")
        let result: LocalProcessResult
        do {
            result = try await LocalProcessRunner.run(
                executable: executable,
                arguments: arguments,
                currentDirectory: directory)
        } catch is CancellationError {
            throw CancellationError()
        } catch AIProviderError.timeout {
            throw AIProviderError.timeout("OpenCode CLI")
        } catch {
            throw AIProviderError.commandFailed("OpenCode CLI")
        }
        guard result.exitCode == 0 else { throw AIProviderError.commandFailed("OpenCode CLI") }
        guard let answer = openCodeText(from: result.standardOutput), !answer.isEmpty else {
            throw AIProviderError.emptyResponse("OpenCode CLI")
        }
        return answer
    }

    private func makeWorkingDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-ai-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func openCodeText(from data: Data) -> String? {
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        var texts: [String] = []
        for line in output.split(separator: "\n") {
            guard let lineData = String(line).data(using: .utf8),
                let event = try? JSONDecoder().decode(OpenCodeEvent.self, from: lineData)
            else { continue }
            if let text = event.part?.text, !text.isEmpty {
                texts.append(text)
            } else if let text = event.text, !text.isEmpty {
                texts.append(text)
            }
        }
        return texts.last?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct OpenCodeIsolationConfiguration: Encodable {
    let permission = "deny"
    let tools = ["*": false]
    let instructions: [String] = []
}

private struct OpenCodeEvent: Decodable {
    struct Part: Decodable {
        let text: String?
    }

    let part: Part?
    let text: String?
}
