import Foundation
import Testing

@testable import MontazhkaKit

@Suite
struct ProjectStoreTests {
    @Test
    func testStoreCreatesDedicatedModelsDirectory() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-models-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(baseDirectory: root)

        #expect(FileManager.default.fileExists(atPath: store.modelsDir.path))
    }

    @Test
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

        #expect((project.schemaVersion) == (Project.currentSchemaVersion))
        #expect((project.clips.first?.source.lastKnownPath) == ("/tmp/source.mov"))
        #expect((project.clips.first?.start) == (1.5))
        #expect((project.clips.first?.end) == (9.0))
    }

    @Test
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

        #expect((project.clips[0].source.id) == (project.clips[1].source.id))
    }

    @Test
    func testProjectFromNewerSchemaIsRejected() {
        let json = """
            {
              "id": "\(UUID().uuidString)",
              "schemaVersion": 999,
              "name": "Проект из будущего",
              "clips": []
            }
            """

        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(Project.self, from: Data(json.utf8))
        }
    }

    @Test
    func testImportedClipKeepsPersistentMediaReference() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-bookmark-\(UUID().uuidString).mov")
        try Data("video-placeholder".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let clip = Clip(sourceURL: url, start: 0, end: 1)

        #expect((clip.source.lastKnownPath) == (url.path))
        #expect((clip.source.bookmarkData) != nil)
    }

    @Test
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

        #expect(
            (URL(fileURLWithPath: clip.sourcePath).resolvingSymlinksInPath().path)
                == (moved.resolvingSymlinksInPath().path))
        let lease = try #require(clip.source.makeAccessLease())
        #expect(lease.url.resolvingSymlinksInPath().path == moved.resolvingSymlinksInPath().path)
    }

    @Test
    func testStoreRoundTripUsesPublicSaveAndLoadContract() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(baseDirectory: root)
        let project = Project(
            name: "Проверка",
            clips: [
                Clip(sourcePath: "/tmp/video.mov", start: 2, end: 7)
            ])

        try await store.save(project)
        let loaded = try await store.load(id: project.id)

        #expect((loaded.name) == ("Проверка"))
        #expect((loaded.clips) == (project.clips))
        #expect((loaded.schemaVersion) == (Project.currentSchemaVersion))
    }

    @Test
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

        #expect((Set(listing.projects.map(\.id))) == (Set([valid.id, legacyID])))
        #expect((listing.issues.count) == (2))
        #expect((Set(listing.issues.map(\.fileName))) == (Set(["damaged.json", "newer.json"])))
    }

    @Test
    func testSaveReportsDirectoryFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-file-\(UUID().uuidString)")
        try Data("occupied".utf8).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(baseDirectory: root)

        do {
            try await store.save(Project(name: "Не запишется"))
            Issue.record("Ожидалась ошибка записи")
        } catch {
            #expect(error is ProjectStoreError)
        }
    }
}
