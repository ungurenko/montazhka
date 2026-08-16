import Foundation
import XCTest
@testable import Montazhka

final class ProjectStoreTests: XCTestCase {
    func testStoreCreatesDedicatedModelsDirectory() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-models-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(baseDirectory: root)

        XCTAssertTrue(FileManager.default.fileExists(atPath: store.modelsDir.path))
    }

    func testLegacyProjectLoadsWithCurrentSchemaAndMediaReference() throws {
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "name": "Старый монтаж",
          "clips": [{
            "id": "\(UUID().uuidString)",
            "sourcePath": "/tmp/source.mov",
            "start": 1.5,
            "end": 9.0
          }],
          "createdAt": "2026-01-01T00:00:00Z",
          "updatedAt": "2026-01-01T00:00:00Z"
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let project = try decoder.decode(Project.self, from: Data(json.utf8))

        XCTAssertEqual(project.schemaVersion, Project.currentSchemaVersion)
        XCTAssertEqual(project.clips.first?.source.lastKnownPath, "/tmp/source.mov")
        XCTAssertEqual(project.clips.first?.start, 1.5)
        XCTAssertEqual(project.clips.first?.end, 9.0)
    }

    func testLegacyClipsFromSameFileShareOneMediaReference() throws {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "name": "Разрезанный монтаж",
          "clips": [
            {"id": "\(UUID().uuidString)", "sourcePath": "/tmp/source.mov", "start": 0, "end": 4},
            {"id": "\(UUID().uuidString)", "sourcePath": "/tmp/source.mov", "start": 8, "end": 12}
          ],
          "createdAt": "2026-01-01T00:00:00Z",
          "updatedAt": "2026-01-01T00:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let project = try decoder.decode(Project.self, from: Data(json.utf8))

        XCTAssertEqual(project.clips[0].source.id, project.clips[1].source.id)
    }

    func testProjectFromNewerSchemaIsRejected() {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "schemaVersion": 999,
          "name": "Проект из будущего",
          "clips": []
        }
        """

        XCTAssertThrowsError(try JSONDecoder().decode(Project.self, from: Data(json.utf8)))
    }

    func testImportedClipKeepsPersistentMediaReference() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-bookmark-\(UUID().uuidString).mov")
        try Data("video-placeholder".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let clip = Clip(sourceURL: url, start: 0, end: 1)

        XCTAssertEqual(clip.source.lastKnownPath, url.path)
        XCTAssertNotNil(clip.source.bookmarkData)
    }

    func testMediaReferenceFollowsFileMove() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-move-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("before.mov")
        let moved = root.appendingPathComponent("after.mov")
        try Data("video-placeholder".utf8).write(to: original)
        let clip = Clip(sourceURL: original, start: 0, end: 1)

        try FileManager.default.moveItem(at: original, to: moved)

        XCTAssertEqual(URL(fileURLWithPath: clip.sourcePath).resolvingSymlinksInPath().path,
                       moved.resolvingSymlinksInPath().path)
    }

    func testStoreRoundTripUsesPublicSaveAndLoadContract() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(baseDirectory: root)
        let project = Project(name: "Проверка", clips: [
            Clip(sourcePath: "/tmp/video.mov", start: 2, end: 7)
        ])

        try await store.save(project)
        let loaded = try await store.load(id: project.id)

        XCTAssertEqual(loaded.name, "Проверка")
        XCTAssertEqual(loaded.clips, project.clips)
        XCTAssertEqual(loaded.schemaVersion, Project.currentSchemaVersion)
    }

    func testListingKeepsValidProjectsWhenAnotherFileIsDamaged() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-list-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(baseDirectory: root)
        let valid = Project(name: "Исправный")
        let legacyID = UUID()
        try await store.save(valid)
        let legacy = """
        {
          "id":"\(legacyID.uuidString)",
          "name":"Старый проект",
          "clips":[],
          "createdAt":"2026-01-01T00:00:00Z",
          "updatedAt":"2026-01-01T00:00:00Z"
        }
        """
        try Data(legacy.utf8).write(
            to: store.projectsDir.appendingPathComponent("legacy.json")
        )
        try Data("{broken-json".utf8).write(
            to: store.projectsDir.appendingPathComponent("damaged.json")
        )
        let newer = """
        {"id":"\(UUID().uuidString)","schemaVersion":999,"name":"Из будущего","clips":[]}
        """
        try Data(newer.utf8).write(
            to: store.projectsDir.appendingPathComponent("newer.json")
        )

        let listing = try await store.listProjects()

        XCTAssertEqual(Set(listing.projects.map(\.id)), Set([valid.id, legacyID]))
        XCTAssertEqual(listing.issues.count, 2)
        XCTAssertEqual(Set(listing.issues.map(\.fileName)), Set(["damaged.json", "newer.json"]))
    }

    func testSaveReportsDirectoryFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-file-\(UUID().uuidString)")
        try Data("occupied".utf8).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(baseDirectory: root)

        do {
            try await store.save(Project(name: "Не запишется"))
            XCTFail("Ожидалась ошибка записи")
        } catch {
            XCTAssertTrue(error is ProjectStoreError)
        }
    }
}
