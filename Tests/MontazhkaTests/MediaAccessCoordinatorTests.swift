import Foundation
import Testing

@testable import MontazhkaKit

@MainActor
@Suite
struct MediaAccessCoordinatorTests {
    @Test
    func unavailableSourcesAreUniqueAndIgnoreAvailableFiles() throws {
        let availableURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-available-\(UUID().uuidString).mov")
        try Data("video".utf8).write(to: availableURL)
        defer { try? FileManager.default.removeItem(at: availableURL) }
        let available = MediaReference(path: availableURL.path)
        let missing = MediaReference(path: "/tmp/montazhka-missing-\(UUID().uuidString).mov")
        let repeated = (0..<78).map { index in
            Clip(source: available, start: Double(index), end: Double(index + 1))
        }
        #expect(uniqueMediaSources(in: repeated).map(\.id) == [available.id])
        let sources = uniqueMediaSources(in: [
            Clip(source: available, start: 0, end: 1),
            Clip(source: missing, start: 0, end: 1),
            Clip(source: missing, start: 1, end: 2),
        ])

        #expect(unavailableMediaSources(sources).map(\.id) == [missing.id])
        #expect(sources.compactMap { $0.resolvedURL?.path } == [availableURL.path])
    }

    @Test
    func deletedMissingSourceCannotReturnAsAStaleWarning() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-missing-race-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = MediaReference(path: "/tmp/montazhka-stale-\(UUID().uuidString).mov")
        let clip = Clip(source: missing, start: 0, end: 1)
        let controller = EditorController(
            project: Project(name: "Гонка", clips: [clip]),
            store: ProjectStore(baseDirectory: root),
            openRouterKeyStore: EmptyOpenRouterKeyStore())

        controller.deleteClip(id: clip.id)
        try? await Task.sleep(for: .milliseconds(100))

        #expect(controller.missingSources.isEmpty)
        #expect(controller.missingFilesMessage == nil)
        await controller.shutdown()
    }

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
