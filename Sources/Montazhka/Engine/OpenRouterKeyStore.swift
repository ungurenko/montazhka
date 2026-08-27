import Foundation

enum OpenRouterKeyStoreError: LocalizedError {
    case storage

    var errorDescription: String? {
        "Не удалось сохранить ключ OpenRouter на этом Mac."
    }
}

protocol OpenRouterKeyStoring: Sendable {
    func load() async throws -> String?
    func save(_ key: String) async throws
    func delete() async throws
}

actor OpenRouterKeyStore: OpenRouterKeyStoring {
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
    }

    func load() throws -> String? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let value = try String(contentsOf: fileURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        } catch {
            throw OpenRouterKeyStoreError.storage
        }
    }

    func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { try delete(); return }
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path)
            try Data(trimmed.utf8).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path)
        } catch {
            throw OpenRouterKeyStoreError.storage
        }
    }

    func delete() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            throw OpenRouterKeyStoreError.storage
        }
    }

    private static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("ru.ungurenko.montazhka", isDirectory: true)
            .appendingPathComponent("OpenRouter", isDirectory: true)
            .appendingPathComponent("openrouter-api-key")
    }
}

/// Пустое хранилище для тестов и встроенной самопроверки.
struct EmptyOpenRouterKeyStore: OpenRouterKeyStoring, Sendable {
    func load() async throws -> String? { nil }
    func save(_ key: String) async throws {}
    func delete() async throws {}
}
