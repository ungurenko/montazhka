import Foundation

/// Встроенная мелодия из папки Music внутри приложения.
struct MusicTrack: Identifiable, Equatable {
    /// Имя файла без расширения — оно же сохраняется в проекте.
    let id: String
    let title: String
    let url: URL
}

/// Каталог встроенных мелодий: содержимое Contents/Resources/Music.
/// Названия берутся из имён файлов (например «Спокойная 1.m4a»).
enum MusicLibrary {
    static let tracks: [MusicTrack] = loadTracks()

    static func track(id: String) -> MusicTrack? {
        tracks.first { $0.id == id }
    }

    private static let audioExtensions: Set<String> = ["m4a", "mp3", "aac", "wav", "aiff", "caf"]

    private static func loadTracks() -> [MusicTrack] {
        guard let dir = musicDirectory() else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return files
            .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
            .map { url in
                let name = url.deletingPathExtension().lastPathComponent
                return MusicTrack(id: name, title: name, url: url)
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private static func musicDirectory() -> URL? {
        // Собранное приложение: Contents/Resources/Music
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Music"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        // Запуск из .build/debug (разработка, selftest): Resources/Music рядом с исходниками
        let dev = URL(fileURLWithPath: #filePath)             // …/Sources/Montazhka/Engine/MusicLibrary.swift
            .deletingLastPathComponent()                       // Engine
            .deletingLastPathComponent()                       // Montazhka
            .deletingLastPathComponent()                       // Sources
            .deletingLastPathComponent()                       // корень проекта
            .appendingPathComponent("Resources/Music")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }
}
