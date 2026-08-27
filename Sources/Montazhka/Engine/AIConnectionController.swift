import Foundation
import Observation

@MainActor
@Observable
final class AIConnectionController {
    private var selectedProvider: AIProvider
    private var selectedModelID: String
    var reasoningChoice: ReasoningChoice {
        didSet { reasoningChoice.save(key: reasoningPreferenceKey, in: preferences) }
    }

    private(set) var agents = AIProvider.allCases.map(AIAgentAvailability.checking)
    private(set) var isRefreshing = false
    private(set) var reasoningOptions: [ReasoningChoice] = [.auto]

    private let preferences: any PreferenceStoring
    private let reasoningPreferenceKey: String
    private let openRouter: OpenRouterClient
    private let keyManager: OpenRouterKeyManager
    @ObservationIgnored private let discoveryOperation = LatestOperation()
    @ObservationIgnored private let reasoningOperation = LatestOperation()

    init(
        preferences: any PreferenceStoring,
        reasoningPreferenceKey: String,
        openRouter: OpenRouterClient,
        keyStore: any OpenRouterKeyStoring
    ) {
        let provider = AIProvider.saved(in: preferences)
        selectedProvider = provider
        selectedModelID = provider.savedModelID(in: preferences)
        reasoningChoice = ReasoningChoice.saved(key: reasoningPreferenceKey, in: preferences)
        self.preferences = preferences
        self.reasoningPreferenceKey = reasoningPreferenceKey
        self.openRouter = openRouter
        keyManager = OpenRouterKeyManager(store: keyStore)
        keyManager.refresh()
    }

    var provider: AIProvider {
        get { selectedProvider }
        set {
            guard newValue != selectedProvider else { return }
            selectedProvider = newValue
            selectedProvider.save(in: preferences)
            selectedModelID = selectedProvider.savedModelID(in: preferences)
            refreshReasoningOptions()
        }
    }

    var modelID: String {
        get { selectedModelID }
        set {
            guard newValue != selectedModelID else { return }
            selectedModelID = newValue
            selectedProvider.saveModelID(newValue, in: preferences)
            refreshReasoningOptions()
        }
    }

    var models: [AIModelOption] {
        selectedAgent?.models ?? []
    }

    var isReady: Bool {
        if selectedProvider == .openRouter { return keyManager.status == .saved }
        guard let selectedAgent else { return false }
        return selectedAgent.isAvailable && selectedAgent.models.contains { $0.id == selectedModelID }
    }

    var selectionTitle: String {
        let modelTitle = models.first(where: { $0.id == selectedModelID })?.title ?? selectedModelID
        return "\(selectedProvider.title) · \(modelTitle)"
    }

    var openRouterKeyStatus: OpenRouterKeyStatus { keyManager.status }

    func refreshAgents(force: Bool = false) {
        isRefreshing = true
        discoveryOperation.start { [weak self] token in
            guard let self else { return }
            let discovered = await AIAgentDiscovery.shared.discover(force: force)
            guard self.discoveryOperation.isCurrent(token) else { return }
            self.agents = discovered
            self.isRefreshing = false
            self.selectFirstAvailableModelIfNeeded()
            self.refreshReasoningOptions()
        }
    }

    func refreshReasoningOptions() {
        let requestedProvider = selectedProvider
        let requestedModelID = selectedModelID
        let localModel = models.first { $0.id == requestedModelID }
        reasoningOperation.start { [weak self] token in
            guard let self else { return }
            let options: [ReasoningChoice]
            switch requestedProvider {
            case .openRouter:
                do {
                    guard let model = SmartEditModel(rawValue: requestedModelID),
                        let apiKey = try await self.keyManager.load()
                    else { return }
                    let capabilities = try await self.openRouter.reasoningCapabilities(
                        for: model, apiKey: apiKey)
                    options = ReasoningChoice.options(
                        availableEfforts: capabilities.efforts,
                        mandatory: capabilities.mandatory)
                } catch {
                    return
                }
            case .codexCLI:
                options = ReasoningChoice.options(
                    availableEfforts: localModel?.supportedEfforts,
                    mandatory: false)
            case .openCodeCLI:
                options = [.auto]
            }
            guard self.reasoningOperation.isCurrent(token),
                self.selectedProvider == requestedProvider,
                self.selectedModelID == requestedModelID
            else { return }
            self.reasoningOptions = options
            if !options.contains(self.reasoningChoice) {
                self.reasoningChoice = .auto
            }
        }
    }

    func requestConfiguration() async throws -> AIRequestConfiguration {
        let provider = selectedProvider
        let modelID = selectedModelID
        let effort = reasoningOptions.contains(reasoningChoice) ? reasoningChoice.apiEffort : nil
        switch provider {
        case .openRouter:
            guard let model = SmartEditModel(rawValue: modelID) else {
                throw AIProviderError.modelUnavailable(modelID)
            }
            guard let apiKey = try await keyManager.load() else {
                throw AIProviderError.missingCredential("OpenRouter")
            }
            return .openRouter(model: model, effort: effort, apiKey: apiKey)
        case .codexCLI, .openCodeCLI:
            guard let agent = agents.first(where: { $0.provider == provider }),
                agent.isAvailable,
                agent.models.contains(where: { $0.id == modelID }),
                let path = agent.executablePath
            else { throw AIProviderError.agentUnavailable(provider.title) }
            let executable = URL(fileURLWithPath: path)
            if provider == .codexCLI {
                return .codexCLI(modelID: modelID, effort: effort, executable: executable)
            }
            return .openCodeCLI(modelID: modelID, effort: effort, executable: executable)
        }
    }

    func refreshOpenRouterKeyState() { keyManager.refresh() }

    func saveAndValidateOpenRouterKey(_ key: String) async {
        await keyManager.saveAndValidate(key)
        refreshReasoningOptions()
    }

    func validateSavedOpenRouterKey() async { await keyManager.validateSaved() }

    func deleteOpenRouterKey() async -> Bool { await keyManager.delete() }

    func shutdown() {
        discoveryOperation.cancel()
        reasoningOperation.cancel()
        keyManager.cancel()
    }

    private var selectedAgent: AIAgentAvailability? {
        agents.first { $0.provider == selectedProvider }
    }

    private func selectFirstAvailableModelIfNeeded() {
        guard selectedProvider != .openRouter,
            let selectedAgent,
            selectedAgent.isAvailable,
            !selectedAgent.models.contains(where: { $0.id == selectedModelID }),
            let first = selectedAgent.models.first
        else { return }
        selectedModelID = first.id
        selectedProvider.saveModelID(first.id, in: preferences)
    }
}
