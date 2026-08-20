import Foundation
import Security

enum OpenRouterKeyStoreError: LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        "Не удалось сохранить ключ в защищённом хранилище macOS."
    }
}

protocol OpenRouterKeyStoring: Sendable {
    func load() async throws -> String?
    func save(_ key: String) async throws
    func delete() async throws
}

actor OpenRouterKeyStore: OpenRouterKeyStoring {
    // Новое имя отделяет ключ от записей, созданных временно подписанными сборками.
    // После первого сохранения доступ сохраняется и для следующих обновлений приложения.
    private let service = "ru.ungurenko.montazhka.openrouter.v2"
    private let account = "openrouter-api-key"

    func load() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
            let data = result as? Data,
            let value = String(data: data, encoding: .utf8)
        else {
            throw OpenRouterKeyStoreError.keychain(status)
        }
        return value
    }

    func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { try delete(); return }
        let data = Data(trimmed.utf8)
        let status = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var query = baseQuery
            query[kSecValueData as String] = data
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw OpenRouterKeyStoreError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw OpenRouterKeyStoreError.keychain(status)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw OpenRouterKeyStoreError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// Хранилище без доступа к связке ключей — для тестов и встроенной самопроверки.
struct EmptyOpenRouterKeyStore: OpenRouterKeyStoring, Sendable {
    func load() async throws -> String? { nil }
    func save(_ key: String) async throws {}
    func delete() async throws {}
}
