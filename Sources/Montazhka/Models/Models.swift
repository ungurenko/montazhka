import Foundation

/// Кусок исходного видео на ленте: файл + границы внутри него (в секундах).
struct Clip: Identifiable, Codable, Equatable {
    var id = UUID()
    var sourcePath: String
    var start: Double
    var end: Double

    var duration: Double { max(0, end - start) }
    var url: URL { URL(fileURLWithPath: sourcePath) }
    var fileName: String { url.deletingPathExtension().lastPathComponent }
}

/// Настройки поиска пауз — сохраняются вместе с проектом.
struct DetectionSettings: Codable, Equatable {
    /// Громкость (дБ), ниже которой звук считается тишиной.
    var thresholdDB: Double = -40
    /// Минимальная длина тихого участка, чтобы считать его паузой (сек).
    var minPauseDuration: Double = 0.8
    /// Сколько «воздуха» оставить с каждого края паузы (мс).
    var paddingMS: Double = 150
}

/// Настройки улучшения голоса — сохраняются вместе с проектом.
struct VoiceEnhanceSettings: Codable, Equatable {
    var enabled = false
    /// «Выравнивание громкости» 0–100.
    var leveling: Double = 50
    /// «Чистка шума» 0–100.
    var noiseReduction: Double = 50
    /// «Звонкость» 0–100.
    var presence: Double = 50

    /// Ключ варианта настроек для кэша (целые — чтобы флоат-шум не плодил файлы).
    var cacheKey: String { "v1|\(Int(leveling))|\(Int(noiseReduction))|\(Int(presence))" }
}

/// Настройки фоновой музыки — сохраняются вместе с проектом.
struct MusicSettings: Codable, Equatable {
    var enabled = false
    /// Идентификатор встроенной мелодии (имя файла без расширения).
    var trackID: String?
    /// Путь к своему аудиофайлу; если задан — важнее встроенной мелодии.
    var customPath: String?
    /// Громкость музыки 0–100 (голос всегда 100).
    var volume: Double = 18
}

struct Project: Identifiable, Codable {
    var id = UUID()
    var name: String
    var clips: [Clip] = []
    var createdAt = Date()
    var updatedAt = Date()
    var detection = DetectionSettings()
    var voiceEnhance = VoiceEnhanceSettings()
    var music = MusicSettings()

    var totalDuration: Double { clips.reduce(0) { $0 + $1.duration } }
}

// Свой распаковщик: старые файлы проектов без новых полей должны открываться как раньше.
// (encode(to:) остаётся автоматическим; init(from:) в extension сохраняет обычный init.)
extension Project {
    private enum CodingKeys: String, CodingKey {
        case id, name, clips, createdAt, updatedAt, detection, voiceEnhance, music
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        clips = try c.decodeIfPresent([Clip].self, forKey: .clips) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        detection = try c.decodeIfPresent(DetectionSettings.self, forKey: .detection) ?? DetectionSettings()
        voiceEnhance = try c.decodeIfPresent(VoiceEnhanceSettings.self, forKey: .voiceEnhance) ?? VoiceEnhanceSettings()
        music = try c.decodeIfPresent(MusicSettings.self, forKey: .music) ?? MusicSettings()
    }
}

/// Лёгкая карточка проекта для стартового экрана.
struct ProjectMeta: Identifiable {
    let id: UUID
    let name: String
    let updatedAt: Date
    let duration: Double
    let clipCount: Int
}
