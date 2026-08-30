import Foundation

struct AgentIntegrationStatus: Sendable {
    let installed: Bool
    let message: String
}

enum AgentIntegrationError: LocalizedError {
    case unavailableExecutable
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailableExecutable: "Не удалось найти исполняемый файл Монтажки."
        case .commandFailed(let value): value
        }
    }
}

enum AgentIntegrationInstaller {
    private static let markerStart = "# >>> Montazhka managed PATH >>>"
    private static let markerEnd = "# <<< Montazhka managed PATH <<<"

    static func status() -> AgentIntegrationStatus {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let wrapper = home.appendingPathComponent(".local/bin/montazhka")
        let binaryPath = (try? String(contentsOf: wrapper, encoding: .utf8))?
            .split(separator: "\n")
            .first { $0.hasPrefix("# Montazhka executable: ") }?
            .dropFirst("# Montazhka executable: ".count)
        let skills = [
            home.appendingPathComponent(".codex/skills/montazhka/SKILL.md"),
            home.appendingPathComponent(".claude/skills/montazhka/SKILL.md"),
        ]
        let installed =
            FileManager.default.isExecutableFile(atPath: wrapper.path)
            && binaryPath.map { FileManager.default.isExecutableFile(atPath: String($0)) } == true
            && skills.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
        return AgentIntegrationStatus(
            installed: installed,
            message: installed ? "AI-агенты подключены" : "AI-агенты ещё не подключены")
    }

    static func install(executable binaryURL: URL? = nil) async throws -> AgentIntegrationStatus {
        let binary = binaryURL ?? Bundle.main.executableURL
        guard let binary, FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw AgentIntegrationError.unavailableExecutable
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let binDirectory = home.appendingPathComponent(".local/bin", isDirectory: true)
        let wrapper = binDirectory.appendingPathComponent("montazhka")
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let escaped = binary.path.replacingOccurrences(of: "'", with: "'\\''")
        let script = "#!/bin/sh\n# Montazhka executable: \(binary.path)\nexec '\(escaped)' agent \"$@\"\n"
        try Data(script.utf8).write(to: wrapper, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        try updateShellPath(home: home)
        try installSkill(at: home.appendingPathComponent(".codex/skills/montazhka/SKILL.md"))
        try installSkill(at: home.appendingPathComponent(".claude/skills/montazhka/SKILL.md"))

        if let codex = executable(named: "codex") {
            _ = try? await run(codex, ["mcp", "remove", "montazhka"])
            try await run(codex, ["mcp", "add", "montazhka", "--", wrapper.path, "mcp", "serve"])
        }
        if let claude = executable(named: "claude") {
            _ = try? await run(claude, ["mcp", "remove", "--scope", "user", "montazhka"])
            try await run(claude, ["mcp", "add", "--scope", "user", "montazhka", "--", wrapper.path, "mcp", "serve"])
        }
        return AgentIntegrationStatus(installed: true, message: "AI-агенты подключены")
    }

    static func uninstall() async throws -> AgentIntegrationStatus {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let managed = [
            home.appendingPathComponent(".local/bin/montazhka"),
            home.appendingPathComponent(".codex/skills/montazhka"),
            home.appendingPathComponent(".claude/skills/montazhka"),
        ]
        for url in managed where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try updateShellPath(home: home, remove: true)
        if let codex = executable(named: "codex") { _ = try? await run(codex, ["mcp", "remove", "montazhka"]) }
        if let claude = executable(named: "claude") {
            _ = try? await run(claude, ["mcp", "remove", "--scope", "user", "montazhka"])
        }
        return AgentIntegrationStatus(installed: false, message: "AI-агенты отключены")
    }

    private static func installSkill(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(AgentDocumentation.skill.utf8).write(to: url, options: .atomic)
    }

    private static func updateShellPath(home: URL, remove: Bool = false) throws {
        let url = home.appendingPathComponent(".zprofile")
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if let start = text.range(of: markerStart),
            let end = text.range(of: markerEnd, range: start.upperBound..<text.endIndex)
        {
            text.removeSubrange(start.lowerBound..<end.upperBound)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        }
        if !remove {
            text += "\n\(markerStart)\nexport PATH=\"$HOME/.local/bin:$PATH\"\n\(markerEnd)\n"
        }
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    private static func executable(named name: String) -> URL? {
        let pathCandidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent(name) }
        let candidates =
            pathCandidates + [
                URL(fileURLWithPath: "/opt/homebrew/bin/\(name)"),
                URL(fileURLWithPath: "/usr/local/bin/\(name)"),
            ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    @discardableResult
    private static func run(_ executable: URL, _ arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("montazhka-command-\(UUID().uuidString).log")
            FileManager.default.createFile(atPath: outputURL.path, contents: nil)
            guard let output = try? FileHandle(forWritingTo: outputURL) else {
                continuation.resume(throwing: CocoaError(.fileWriteUnknown))
                return
            }
            process.executableURL = executable; process.arguments = arguments
            process.standardOutput = output; process.standardError = output
            process.terminationHandler = { process in
                try? output.close()
                let text = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
                try? FileManager.default.removeItem(at: outputURL)
                if process.terminationStatus == 0 {
                    continuation.resume(returning: text)
                } else {
                    continuation.resume(
                        throwing: AgentIntegrationError.commandFailed(
                            text.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
            do { try process.run() } catch {
                try? output.close()
                try? FileManager.default.removeItem(at: outputURL)
                continuation.resume(throwing: error)
            }
        }
    }
}
