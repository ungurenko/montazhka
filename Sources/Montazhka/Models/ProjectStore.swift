import Foundation

enum ProjectStoreError: LocalizedError {
    case prepareDirectory(String)
    case encode(String)
    case write(String)
    case read(String)
    case decode(String)
    case delete(String)

    var errorDescription: String? {
        switch self {
        case .prepareDirectory(let value): return "Не удалось подготовить папку проектов: \(value)"
        case .encode(let value): return "Не удалось подготовить проект к сохранению: \(value)"
        case .write(let value): return "Не удалось сохранить проект: \(value)"
        case .read(let value): return "Не удалось прочитать проект: \(value)"
        case .decode(let value): return "Файл проекта повреждён или создан новой версией: \(value)"
        case .delete(let value): return "Не удалось удалить проект: \(value)"
        }
    }
}

struct ProjectListIssue: Equatable {
    let fileName: String
    let message: String
}

struct ProjectListing {
    let projects: [ProjectMeta]
    let issues: [ProjectListIssue]
}

/// Хранит проекты как JSON-файлы в Application Support — исходные видео не трогаются.
final class ProjectStore {
    let projectsDir: URL
    let waveformsDir: URL
    let enhancedAudioDir: URL
    let musicEQDir: URL
    let transcriptsDir: URL

    private let baseDirectory: URL

    init(baseDirectory: URL? = nil) {
        let base = baseDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Montazhka", isDirectory: true)
        self.baseDirectory = base
        projectsDir = base.appendingPathComponent("Projects", isDirectory: true)
        waveformsDir = base.appendingPathComponent("Waveforms", isDirectory: true)
        enhancedAudioDir = base.appendingPathComponent("EnhancedAudio", isDirectory: true)
        musicEQDir = base.appendingPathComponent("MusicEQ", isDirectory: true)
        transcriptsDir = base.appendingPathComponent("Transcripts", isDirectory: true)
        try? prepareDirectories()
    }

    private func fileURL(for id: UUID) -> URL {
        projectsDir.appendingPathComponent("\(id.uuidString).json")
    }

    private func prepareDirectories() throws {
        do {
            try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: waveformsDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: enhancedAudioDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: musicEQDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: transcriptsDir, withIntermediateDirectories: true)
        } catch {
            throw ProjectStoreError.prepareDirectory(error.localizedDescription)
        }
    }

    func save(_ project: Project) throws {
        try prepareDirectories()
        var p = project
        p.schemaVersion = Project.currentSchemaVersion
        p.updatedAt = Date()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        do { data = try encoder.encode(p) }
        catch { throw ProjectStoreError.encode(error.localizedDescription) }
        do { try data.write(to: fileURL(for: p.id), options: .atomic) }
        catch { throw ProjectStoreError.write(error.localizedDescription) }
    }

    func load(id: UUID) throws -> Project {
        let data: Data
        do { data = try Data(contentsOf: fileURL(for: id)) }
        catch { throw ProjectStoreError.read(error.localizedDescription) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(Project.self, from: data) }
        catch { throw ProjectStoreError.decode(error.localizedDescription) }
    }

    func delete(id: UUID) throws {
        do { try FileManager.default.trashItem(at: fileURL(for: id), resultingItemURL: nil) }
        catch { throw ProjectStoreError.delete(error.localizedDescription) }
    }

    func listProjects() throws -> ProjectListing {
        try prepareDirectories()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files: [URL]
        do { files = try FileManager.default.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil) }
        catch { throw ProjectStoreError.read(error.localizedDescription) }
        var projects: [ProjectMeta] = []
        var issues: [ProjectListIssue] = []
        for url in files where url.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: url)
                let project = try decoder.decode(Project.self, from: data)
                projects.append(ProjectMeta(id: project.id, name: project.name,
                                            updatedAt: project.updatedAt,
                                            duration: project.totalDuration,
                                            clipCount: project.clips.count))
            } catch {
                issues.append(ProjectListIssue(fileName: url.lastPathComponent,
                                               message: error.localizedDescription))
            }
        }
        return ProjectListing(projects: projects.sorted { $0.updatedAt > $1.updatedAt },
                              issues: issues)
    }

    static func defaultProjectName() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMMM"
        return "Монтаж \(f.string(from: Date()))"
    }
}
