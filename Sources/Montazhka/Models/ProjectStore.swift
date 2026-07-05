import Foundation

/// Хранит проекты как JSON-файлы в Application Support — исходные видео не трогаются.
final class ProjectStore {
    let projectsDir: URL
    let waveformsDir: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Montazhka", isDirectory: true)
        projectsDir = base.appendingPathComponent("Projects", isDirectory: true)
        waveformsDir = base.appendingPathComponent("Waveforms", isDirectory: true)
        try? FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: waveformsDir, withIntermediateDirectories: true)
    }

    private func fileURL(for id: UUID) -> URL {
        projectsDir.appendingPathComponent("\(id.uuidString).json")
    }

    func save(_ project: Project) {
        var p = project
        p.updatedAt = Date()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(p) else { return }
        try? data.write(to: fileURL(for: p.id), options: .atomic)
    }

    func load(id: UUID) -> Project? {
        guard let data = try? Data(contentsOf: fileURL(for: id)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Project.self, from: data)
    }

    func delete(id: UUID) {
        try? FileManager.default.trashItem(at: fileURL(for: id), resultingItemURL: nil)
    }

    func listProjects() -> [ProjectMeta] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil)) ?? []
        let projects: [ProjectMeta] = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let p = try? decoder.decode(Project.self, from: data) else { return nil }
                return ProjectMeta(id: p.id, name: p.name, updatedAt: p.updatedAt,
                                   duration: p.totalDuration, clipCount: p.clips.count)
            }
        return projects.sorted { $0.updatedAt > $1.updatedAt }
    }

    static func defaultProjectName() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMMM"
        return "Монтаж \(f.string(from: Date()))"
    }
}
