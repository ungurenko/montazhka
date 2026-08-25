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
