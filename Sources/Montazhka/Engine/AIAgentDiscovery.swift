import Foundation

actor AIAgentDiscovery {
    static let shared = AIAgentDiscovery()

    private var cached: [AIAgentAvailability]?

    func discover(force: Bool = false) async -> [AIAgentAvailability] {
        if !force, let cached { return cached }
        async let codex = discoverCodex()
        async let openCode = discoverOpenCode()
        let entries = await [AIAgentAvailability.openRouter, codex, openCode]
        cached = entries
        return entries
    }

    private func discoverCodex() async -> AIAgentAvailability {
        guard let executable = executable(named: "codex", extraPaths: []) else {
            return unavailable(.codexCLI, "Codex CLI не установлен")
        }
        do {
            async let catalogResult = LocalProcessRunner.run(
                executable: executable,
                arguments: ["debug", "models"],
                timeout: 15)
            async let loginResult = LocalProcessRunner.run(
                executable: executable,
                arguments: ["login", "status"],
                timeout: 8)
            let (catalog, login) = try await (catalogResult, loginResult)
            guard login.exitCode == 0 else {
                return unavailable(
                    .codexCLI, "Codex CLI найден, но требуется вход", path: executable.path)
            }
            let models = codexModels(from: catalog.standardOutput)
            guard catalog.exitCode == 0, !models.isEmpty else {
                return unavailable(
                    .codexCLI, "Codex CLI найден, список моделей недоступен", path: executable.path)
            }
            return AIAgentAvailability(
                provider: .codexCLI,
                isAvailable: true,
                executablePath: executable.path,
                models: models,
                message: nil)
        } catch {
            return unavailable(.codexCLI, "Codex CLI найден, но не отвечает", path: executable.path)
        }
    }

    private func discoverOpenCode() async -> AIAgentAvailability {
        guard
            let executable = executable(
                named: "opencode",
                extraPaths: [".opencode/bin", ".local/bin"])
        else {
            return unavailable(.openCodeCLI, "OpenCode CLI не установлен")
        }
        do {
            let result = try await LocalProcessRunner.run(
                executable: executable,
                arguments: ["models"],
                timeout: 30)
            guard result.exitCode == 0 else {
                return unavailable(.openCodeCLI, "OpenCode CLI найден, но не авторизован", path: executable.path)
            }
            let models = openCodeModels(from: result.standardOutput)
            guard !models.isEmpty else {
                return unavailable(.openCodeCLI, "OpenCode CLI найден, список моделей пуст", path: executable.path)
            }
            return AIAgentAvailability(
                provider: .openCodeCLI,
                isAvailable: true,
                executablePath: executable.path,
                models: models,
                message: nil)
        } catch {
            return unavailable(.openCodeCLI, "OpenCode CLI найден, но не отвечает", path: executable.path)
        }
    }

    private func unavailable(
        _ provider: AIProvider,
        _ message: String,
        path: String? = nil
    ) -> AIAgentAvailability {
        AIAgentAvailability(
            provider: provider,
            isAvailable: false,
            executablePath: path,
            models: [],
            message: message)
    }

    private func executable(named name: String, extraPaths: [String]) -> URL? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        var candidates = extraPaths.map { home.appendingPathComponent($0).appendingPathComponent(name) }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        candidates += path.split(separator: ":").map {
            URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent(name)
        }
        candidates += [
            URL(fileURLWithPath: "/usr/local/bin/\(name)"),
            URL(fileURLWithPath: "/opt/homebrew/bin/\(name)"),
            home.appendingPathComponent(".local/bin/\(name)"),
        ]
        var seen = Set<String>()
        return candidates.first { candidate in
            seen.insert(candidate.path).inserted && fileManager.isExecutableFile(atPath: candidate.path)
        }
    }

    private func codexModels(from data: Data) -> [AIModelOption] {
        guard let catalog = try? JSONDecoder().decode(CodexModelCatalog.self, from: data) else {
            return []
        }
        return catalog.models.compactMap { model in
            guard !model.slug.isEmpty, model.visibility != "hidden" else { return nil }
            return AIModelOption(
                id: model.slug,
                title: model.displayName,
                supportedEfforts: model.supportedReasoningLevels.compactMap {
                    ReasoningEffort(rawValue: $0.effort)
                }
            )
        }
    }

    private func openCodeModels(from data: Data) -> [AIModelOption] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let ansi = try? NSRegularExpression(pattern: "\\u001B\\[[0-9;]*[A-Za-z]")
        return text.components(separatedBy: .newlines).compactMap { rawLine in
            let range = NSRange(rawLine.startIndex..., in: rawLine)
            let line =
                ansi?.stringByReplacingMatches(in: rawLine, range: range, withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? rawLine
            guard line.contains("/"), !line.contains(" ") else { return nil }
            return AIModelOption(id: line)
        }
    }
}

private struct CodexModelCatalog: Decodable {
    struct Model: Decodable {
        struct ReasoningLevel: Decodable {
            let effort: String
        }

        let slug: String
        let displayName: String
        let supportedReasoningLevels: [ReasoningLevel]
        let visibility: String?

        enum CodingKeys: String, CodingKey {
            case slug
            case displayName = "display_name"
            case supportedReasoningLevels = "supported_reasoning_levels"
            case visibility
        }
    }

    let models: [Model]
}
