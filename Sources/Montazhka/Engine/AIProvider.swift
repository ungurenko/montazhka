import Foundation

enum AIProvider: String, CaseIterable, Codable, Identifiable, Sendable, StoredPreference {
    case openRouter
    case codexCLI
    case openCodeCLI

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openRouter: return "OpenRouter"
        case .codexCLI: return "Codex CLI"
        case .openCodeCLI: return "OpenCode CLI"
        }
    }

    static let key = "ai.provider"
    static let fallback = AIProvider.openRouter

    var modelPreferenceKey: String {
        switch self {
        case .openRouter: return SmartEditModel.key
        case .codexCLI: return "ai.codexCLI.model"
        case .openCodeCLI: return "ai.openCodeCLI.model"
        }
    }

    var fallbackModelID: String {
        switch self {
        case .openRouter: return SmartEditModel.qwen.rawValue
        case .codexCLI: return "gpt-5.6-luna"
        case .openCodeCLI: return "opencode-go/gpt-5.6-luna"
        }
    }

    func savedModelID(
        in store: any PreferenceStoring = UserDefaultsPreferenceStore.standard
    ) -> String {
        if self == .openRouter { return SmartEditModel.saved(in: store).rawValue }
        return store.string(forKey: modelPreferenceKey) ?? fallbackModelID
    }

    func saveModelID(
        _ modelID: String,
        in store: any PreferenceStoring = UserDefaultsPreferenceStore.standard
    ) {
        store.set(modelID, forKey: modelPreferenceKey)
    }
}

struct AIModelOption: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let supportedEfforts: [ReasoningEffort]?

    init(
        id: String,
        title: String? = nil,
        supportedEfforts: [ReasoningEffort]? = nil
    ) {
        self.id = id
        self.title = title ?? id
        self.supportedEfforts = supportedEfforts
    }
}

struct AIAgentAvailability: Identifiable, Equatable, Sendable {
    let provider: AIProvider
    let isAvailable: Bool
    let executablePath: String?
    let models: [AIModelOption]
    let message: String?

    var id: AIProvider { provider }

    static let openRouter = AIAgentAvailability(
        provider: .openRouter,
        isAvailable: true,
        executablePath: nil,
        models: SmartEditModel.allCases.map {
            AIModelOption(id: $0.rawValue, title: $0.title)
        },
        message: nil)

    static func checking(_ provider: AIProvider) -> AIAgentAvailability {
        if provider == .openRouter { return .openRouter }
        return AIAgentAvailability(
            provider: provider,
            isAvailable: false,
            executablePath: nil,
            models: [],
            message: "Проверяю установку…")
    }
}

enum AIRequestConfiguration: Sendable {
    case openRouter(model: SmartEditModel, effort: String?, apiKey: String)
    case codexCLI(modelID: String, effort: String?, executable: URL)
    case openCodeCLI(modelID: String, effort: String?, executable: URL)

    var provider: AIProvider {
        switch self {
        case .openRouter: return .openRouter
        case .codexCLI: return .codexCLI
        case .openCodeCLI: return .openCodeCLI
        }
    }

    var modelID: String {
        switch self {
        case .openRouter(let model, _, _): return model.rawValue
        case .codexCLI(let modelID, _, _), .openCodeCLI(let modelID, _, _): return modelID
        }
    }

    var effort: String? {
        switch self {
        case .openRouter(_, let effort, _),
            .codexCLI(_, let effort, _),
            .openCodeCLI(_, let effort, _):
            return effort
        }
    }

    /// Сколько окон транскрипта опрашивать одновременно. CLI-агенты запускают
    /// по процессу на вызов — им строго по одному.
    var maxConcurrentWindows: Int {
        switch self {
        case .openRouter: return 3
        case .codexCLI, .openCodeCLI: return 1
        }
    }

    func withEffort(_ effort: String?) -> AIRequestConfiguration {
        switch self {
        case .openRouter(let model, _, let apiKey):
            return .openRouter(model: model, effort: effort, apiKey: apiKey)
        case .codexCLI(let modelID, _, let executable):
            return .codexCLI(modelID: modelID, effort: effort, executable: executable)
        case .openCodeCLI(let modelID, _, let executable):
            return .openCodeCLI(modelID: modelID, effort: effort, executable: executable)
        }
    }
}

enum AIProviderError: LocalizedError, Equatable {
    case agentUnavailable(String)
    case missingCredential(String)
    case modelUnavailable(String)
    case commandFailed(String)
    case timeout(String)
    case emptyResponse(String)

    var errorDescription: String? {
        switch self {
        case .agentUnavailable(let agent):
            return "\(agent) не найден или ещё не готов. Проверь установку и вход в аккаунт."
        case .missingCredential(let provider):
            return "Сначала сохрани ключ \(provider)."
        case .modelUnavailable(let model):
            return "Модель \(model) сейчас недоступна. Обнови список и выбери другую."
        case .commandFailed(let agent):
            return "\(agent) не смог обработать запрос. Проверь вход в аккаунт и попробуй ещё раз."
        case .timeout(let agent):
            return "\(agent) не ответил за три минуты. Попробуй ещё раз или выбери более быструю модель."
        case .emptyResponse(let agent):
            return "\(agent) вернул пустой ответ. Попробуй ещё раз."
        }
    }
}
