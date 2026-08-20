import Foundation
import Testing

@testable import MontazhkaKit

@MainActor
@Suite
struct MediaAccessCoordinatorTests {
    @Test
    func synchronizationReplacesAccessWhenReferenceChangesWithoutChangingID() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstURL = directory.appendingPathComponent("first.mov")
        let secondURL = directory.appendingPathComponent("second.mov")
        try Data().write(to: firstURL)
        try Data().write(to: secondURL)

        var reference = MediaReference(url: firstURL)
        let coordinator = MediaAccessCoordinator()
        coordinator.synchronize([reference])
        #expect(coordinator.url(for: reference)?.standardizedFileURL == firstURL.standardizedFileURL)

        reference.relink(to: secondURL)
        coordinator.synchronize([reference])

        #expect(coordinator.url(for: reference)?.standardizedFileURL == secondURL.standardizedFileURL)
    }
}
