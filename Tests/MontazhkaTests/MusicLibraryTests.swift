import Foundation
import Testing

@testable import MontazhkaKit

@Suite
struct MusicLibraryTests {
    /// Библиотека — статический каталог над Contents/Resources/Music (в dev-режиме
    /// — Resources/App/Music). Чистая логика: фильтр, сортировка, уникальность, lookup.
    @Test
    func testCatalogIsNotEmptyInTestEnvironment() throws {
        try #require(!MusicLibrary.tracks.isEmpty, "Каталог Music пуст — тест окружения, не логики")
    }

    @Test
    func testLookupFindsTrackByIdAndReturnsNilForUnknown() throws {
        let track = try #require(MusicLibrary.tracks.first)
        #expect(MusicLibrary.track(id: track.id) == track)
        #expect(MusicLibrary.track(id: "нет-такого-трека") == nil)
    }

    @Test
    func testCatalogIsSortedByLocalizedStandardCompare() {
        for (current, next) in zip(MusicLibrary.tracks, MusicLibrary.tracks.dropFirst()) {
            #expect(
                current.title.localizedStandardCompare(next.title) != .orderedDescending,
                "Каталог не отсортирован: \(current.title) после \(next.title)")
        }
    }

    @Test
    func testCatalogHasUniqueIdsAndSupportedExtensionsOnDisk() {
        let ids = MusicLibrary.tracks.map(\.id)
        #expect(!ids.isEmpty)
        #expect(Set(ids).count == ids.count, "Дубль id в каталоге")
        for track in MusicLibrary.tracks {
            #expect(track.id == track.title)
            #expect(!track.title.isEmpty)
            #expect(["m4a", "mp3", "aac", "wav", "aiff", "caf"].contains(track.url.pathExtension.lowercased()))
            #expect(FileManager.default.fileExists(atPath: track.url.path), "Файл \(track.url) отсутствует")
        }
    }
}

@Suite("Music moods")
struct MusicMoodTests {
    private func library(_ manifest: String?) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["Бодрая 1", "Бодрая 2", "Тихая 1", "Без описания"] {
            try Data([0]).write(to: dir.appendingPathComponent("\(name).m4a"))
        }
        if let manifest { try Data(manifest.utf8).write(to: dir.appendingPathComponent("manifest.json")) }
        return dir
    }

    private let manifest = """
        {"version":1,"tracks":[
          {"file":"Бодрая 1.m4a","mood":"energetic","energy":4,"bpm":120},
          {"file":"Бодрая 2.m4a","mood":"energetic","energy":5,"bpm":128},
          {"file":"Тихая 1.m4a","mood":"calm","energy":1,"bpm":70}]}
        """

    @Test("the manifest gives tracks a mood, tempo and energy")
    func manifestAddsMood() throws {
        let tracks = MusicLibrary.loadTracks(from: try library(manifest))
        let calm = try #require(tracks.first { $0.id == "Тихая 1" })
        #expect(calm.mood == "calm")
        #expect(calm.bpm == 70)
        #expect(calm.energy == 1)
        #expect(tracks.first { $0.id == "Без описания" }?.mood == nil)
    }

    @Test("without a manifest tracks still load by file name")
    func noManifest() throws {
        let tracks = MusicLibrary.loadTracks(from: try library(nil))
        #expect(tracks.count == 4)
        #expect(tracks.allSatisfy { $0.mood == nil })
    }

    @Test("picking by mood rotates between matching tracks")
    func pickRotates() throws {
        let tracks = MusicLibrary.loadTracks(from: try library(manifest))
        let first = MusicLibrary.pick(mood: "energetic", variant: 0, in: tracks)
        let second = MusicLibrary.pick(mood: "energetic", variant: 1, in: tracks)
        #expect(first?.mood == "energetic")
        #expect(second?.mood == "energetic")
        #expect(first != second)
    }

    @Test("an unknown mood still gets some music")
    func pickFallsBack() throws {
        let tracks = MusicLibrary.loadTracks(from: try library(manifest))
        #expect(MusicLibrary.pick(mood: "jazz", variant: 0, in: tracks) != nil)
        #expect(MusicLibrary.pick(mood: "calm", variant: 0, in: []) == nil)
    }
}

@Suite("Music in doctor")
struct MusicDoctorTests {
    @Test("doctor lists built-in tracks with their moods for the agent")
    func doctorListsMusic() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let response = await AgentService(baseDirectory: root).doctor()
        guard case .array(let music)? = response.data?["music"] else {
            Issue.record("В ответе doctor нет списка music")
            return
        }
        #expect(music.count == MusicLibrary.tracks.count)
        guard case .object(let first)? = music.first else { return }
        #expect(first["id"] == .string(MusicLibrary.tracks[0].id))
    }
}
