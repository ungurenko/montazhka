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

struct Project: Identifiable, Codable {
    var id = UUID()
    var name: String
    var clips: [Clip] = []
    var createdAt = Date()
    var updatedAt = Date()
    var detection = DetectionSettings()

    var totalDuration: Double { clips.reduce(0) { $0 + $1.duration } }
}

/// Лёгкая карточка проекта для стартового экрана.
struct ProjectMeta: Identifiable {
    let id: UUID
    let name: String
    let updatedAt: Date
    let duration: Double
    let clipCount: Int
}
