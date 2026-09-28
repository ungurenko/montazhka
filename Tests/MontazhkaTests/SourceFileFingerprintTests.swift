import Foundation
import Testing

@testable import MontazhkaKit

struct SourceFileFingerprintTests {
    @Test("cache fingerprints keep the existing path-size-seconds format")
    func existingKeyFormat() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-fingerprint-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data([1, 2, 3, 4]).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: file.path)

        #expect(SourceFileFingerprint.key(for: file.path) == "\(file.path)|4|1700000000")
        #expect(SourceFileFingerprint.key(for: file.path + "-missing") == "\(file.path)-missing|0|0")
    }
}
