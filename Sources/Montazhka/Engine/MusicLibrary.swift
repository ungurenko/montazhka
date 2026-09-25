import Foundation

/// Встроенная мелодия из папки Music внутри приложения.
struct MusicTrack: Identifiable, Equatable {
    /// Имя файла без расширения — оно же сохраняется в проекте.
    let id: String
    let title: String
    let url: URL
    /// Настроение из manifest.json: calm, neutral, energetic, inspiring,
    /// playful, tense, emotional. nil — трек не описан.
    var mood: String? = nil
    /// Энергия 1…5.
    var energy: Int? = nil
    var bpm: Int? = nil
}

/// Описание треков рядом с файлами: Music/manifest.json.
private struct MusicManifest: Decodable {
    struct Entry: Decodable {
        let file: String
        let mood: String?
        let energy: Int?
        let bpm: Int?
    }

    let tracks: [Entry]
}

/// Каталог встроенных мелодий: содержимое Contents/Resources/Music.
/// Названия берутся из имён файлов (например «Спокойная 1.m4a»).
enum MusicLibrary {
    static let tracks: [MusicTrack] = musicDirectory().map(loadTracks(from:)) ?? []
    /// Настроения, которыми описаны треки в manifest.json.
    static let moods = ["calm", "neutral", "energetic", "inspiring", "playful", "tense", "emotional"]

    /// Трек нужного настроения. `variant` перебирает подходящие по кругу,
    /// чтобы соседние ролики звучали по-разному. Неизвестное настроение
    /// берёт нейтральные треки, а если их нет — любые.
    static func pick(mood: String, variant: Int, in tracks: [MusicTrack] = tracks) -> MusicTrack? {
        let matching = tracks.filter { $0.mood == mood }
        let neutral = tracks.filter { $0.mood == "neutral" }
        let pool = !matching.isEmpty ? matching : (!neutral.isEmpty ? neutral : tracks)
        guard !pool.isEmpty else { return nil }
        return pool[abs(variant) % pool.count]
    }

    static func track(id: String) -> MusicTrack? {
        tracks.first { $0.id == id }
    }

    private static let audioExtensions: Set<String> = ["m4a", "mp3", "aac", "wav", "aiff", "caf"]

    static func loadTracks(from dir: URL) -> [MusicTrack] {
        let manifest = (try? Data(contentsOf: dir.appendingPathComponent("manifest.json")))
            .flatMap { try? JSONDecoder().decode(MusicManifest.self, from: $0) }
        let entries = Dictionary(
            (manifest?.tracks ?? []).map { ($0.file, $0) }, uniquingKeysWith: { first, _ in first })
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )) ?? []
        return
            files
            .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
            .map { url in
                let name = url.deletingPathExtension().lastPathComponent
                let entry = entries[url.lastPathComponent]
                return MusicTrack(
                    id: name, title: name, url: url,
                    mood: entry?.mood, energy: entry?.energy, bpm: entry?.bpm)
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private static func musicDirectory() -> URL? {
        // Собранное приложение: Contents/Resources/Music
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Music"),
            FileManager.default.fileExists(atPath: bundled.path)
        {
            return bundled
        }
        // Запуск из .build/debug (разработка, selftest): Resources/App/Music.
        let dev = URL(fileURLWithPath: #filePath)  // …/Sources/Montazhka/Engine/MusicLibrary.swift
            .deletingLastPathComponent()  // Engine
            .deletingLastPathComponent()  // Montazhka
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()  // корень проекта
            .appendingPathComponent("Resources/App/Music")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }
}
