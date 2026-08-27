import Foundation
import Testing

@testable import MontazhkaKit

@Suite
struct OpenRouterKeyStoreTests {
    @Test
    func keySurvivesAStoreRestartWithoutKeychain() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-key-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("openrouter-api-key")

        try await OpenRouterKeyStore(fileURL: fileURL).save("  test-key  ")

        let reopenedStore = OpenRouterKeyStore(fileURL: fileURL)
        #expect(try await reopenedStore.load() == "test-key")
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        #expect(attributes[.posixPermissions] as? NSNumber == 0o600)

        try await reopenedStore.delete()
        #expect(try await reopenedStore.load() == nil)
    }
}
