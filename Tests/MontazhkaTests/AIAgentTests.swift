import Foundation
import Testing

@testable import MontazhkaKit

@Suite
struct AIAgentTests {
    @Test
    func providerAndEachAgentModelPersistIndependently() {
        let store = AITestPreferenceStore()

        #expect(AIProvider.saved(in: store) == .openRouter)
        AIProvider.codexCLI.save(in: store)
        AIProvider.codexCLI.saveModelID("gpt-test", in: store)
        AIProvider.openCodeCLI.saveModelID("provider/model-test", in: store)

        #expect(AIProvider.saved(in: store) == .codexCLI)
        #expect(AIProvider.codexCLI.savedModelID(in: store) == "gpt-test")
        #expect(AIProvider.openCodeCLI.savedModelID(in: store) == "provider/model-test")
        #expect(AIProvider.openRouter.savedModelID(in: store) == SmartEditModel.qwen.rawValue)

        store.set("removed-openrouter-model", forKey: SmartEditModel.key)
        #expect(AIProvider.openRouter.savedModelID(in: store) == SmartEditModel.qwen.rawValue)
    }

    @Test
    func cliConfigurationsPreserveTheirExecutableWhenEffortChanges() {
        let executable = URL(fileURLWithPath: "/usr/local/bin/codex")
        let configuration = AIRequestConfiguration.codexCLI(
            modelID: "gpt-test",
            effort: nil,
            executable: executable
        ).withEffort("high")

        guard case .codexCLI(let modelID, let effort, let configuredExecutable) = configuration
        else {
            Issue.record("Ожидалась конфигурация Codex CLI")
            return
        }
        #expect(modelID == "gpt-test")
        #expect(effort == "high")
        #expect(configuredExecutable == executable)
    }

    @Test
    func cliAgentsDisableExternalTools() {
        let disabledFeatures = Set(CLIAgentClient.disabledCodexFeatures)
        #expect(disabledFeatures.contains("shell_tool"))
        #expect(disabledFeatures.contains("unified_exec"))
        #expect(disabledFeatures.contains("plugins"))

        let openCodeConfiguration = OpenCodeIsolationConfiguration()
        #expect(openCodeConfiguration.permission == "deny")
        #expect(openCodeConfiguration.tools["*"] == false)
        #expect(openCodeConfiguration.instructions.isEmpty)
    }

    @Test
    func cancellingLocalProcessStopsItAsCancellation() async throws {
        let task = Task {
            try await LocalProcessRunner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"])
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test @MainActor
    func connectionRestoresTheSavedModelForEachProvider() {
        let store = AITestPreferenceStore()
        AIProvider.codexCLI.saveModelID("gpt-saved", in: store)
        AIProvider.openCodeCLI.saveModelID("provider/model-saved", in: store)
        let connection = AIConnectionController(
            preferences: store,
            reasoningPreferenceKey: "test.reasoning",
            openRouter: OpenRouterClient(),
            keyStore: EmptyOpenRouterKeyStore())
        defer { connection.shutdown() }

        connection.provider = .codexCLI
        #expect(connection.modelID == "gpt-saved")
        connection.provider = .openCodeCLI
        #expect(connection.modelID == "provider/model-saved")
        connection.provider = .codexCLI
        #expect(connection.modelID == "gpt-saved")
    }

    @Test
    func installedAgentsReturnMachineReadableJSONWhenSmokeEnabled() async throws {
        guard ProcessInfo.processInfo.environment["MONTAZHKA_CLI_SMOKE"] == "1" else { return }
        let agents = await AIAgentDiscovery.shared.discover(force: true)
        let client = CLIAgentClient()

        for provider in [AIProvider.codexCLI, .openCodeCLI] {
            guard let agent = agents.first(where: { $0.provider == provider }),
                agent.isAvailable,
                let executablePath = agent.executablePath,
                let model = preferredSmokeModel(for: provider, in: agent.models)
            else {
                let diagnostic = agents.first(where: { $0.provider == provider })?.message ?? "нет записи"
                Issue.record("\(provider.title) должен быть установлен и авторизован: \(diagnostic)")
                continue
            }
            let answer = try await client.complete(
                system: "Верни JSON-объект с полями schema_version=1 и ok=true.",
                user: "Проверка связи.",
                configuration: configuration(
                    provider: provider,
                    modelID: model.id,
                    executablePath: executablePath))
            guard let data = OpenRouterClient.extractedEnvelopeData(answer),
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                Issue.record("\(provider.title) вернул повреждённый JSON")
                continue
            }
            #expect(object["schema_version"] as? Int == 1)
            #expect(object["ok"] as? Bool == true)
        }
    }

    private func configuration(
        provider: AIProvider,
        modelID: String,
        executablePath: String
    ) -> AIRequestConfiguration {
        let executable = URL(fileURLWithPath: executablePath)
        switch provider {
        case .codexCLI:
            return .codexCLI(modelID: modelID, effort: nil, executable: executable)
        case .openCodeCLI:
            return .openCodeCLI(modelID: modelID, effort: nil, executable: executable)
        case .openRouter:
            preconditionFailure("Smoke-тест использует только локальные CLI")
        }
    }

    private func preferredSmokeModel(
        for provider: AIProvider,
        in models: [AIModelOption]
    ) -> AIModelOption? {
        let preferredID = provider == .codexCLI ? "gpt-5.6-luna" : "opencode-go/gpt-5.6-luna"
        return models.first(where: { $0.id == preferredID }) ?? models.first
    }
}

private final class AITestPreferenceStore: PreferenceStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var strings: [String: String] = [:]

    func string(forKey key: String) -> String? {
        lock.withLock { strings[key] }
    }

    func set(_ value: String?, forKey key: String) {
        lock.withLock { strings[key] = value }
    }

    func bool(forKey key: String) -> Bool { false }
    func set(_ value: Bool, forKey key: String) {}
}
