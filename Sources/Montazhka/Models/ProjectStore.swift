import Foundation

/// Ассоциированное значение — техническая причина для лога.
/// В интерфейс она не попадает: там показывают `errorDescription`
/// и `recoverySuggestion`.
enum ProjectStoreError: LocalizedError {
    case prepareDirectory(String)
    case encode(String)
    case write(String)
    case read(String)
    case decode(String)
    case delete(String)

    /// Системная причина живёт в ассоциированном значении и уходит в лог,
    /// а пользователю показывают только понятную половину.
    var errorDescription: String? {
        switch self {
        case .prepareDirectory: return "Не получилось подготовить папку проектов."
        case .encode: return "Не получилось подготовить проект к сохранению."
        case .write: return "Не получилось сохранить проект."
        case .read: return "Не получилось прочитать проект."
        case .decode: return "Файл проекта повреждён или создан более новой версией."
        case .delete: return "Не получилось удалить проект."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .prepareDirectory, .write:
            return "Проверь свободное место на диске и права на папку с проектами."
        case .encode, .decode:
            return "Проект открыть не выйдет, но остальные останутся на месте."
        case .read:
            return "Попробуй открыть его ещё раз или выбери другой проект."
        case .delete:
            return "Попробуй ещё раз или удали файл проекта вручную."
        }
    }
}

struct ProjectListIssue: Equatable, Sendable {
    let fileName: String
    let message: String
}

struct ProjectListing: Sendable {
    let projects: [ProjectMeta]
    let issues: [ProjectListIssue]
}

/// Лёгкие метаданные карточки проекта — пишутся рядом с основным JSON,
/// чтобы список проектов не декодировал полные файлы.
private struct ProjectSidecarMeta: Codable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var name: String
    var updatedAt: Date
    var duration: Double
    var clipCount: Int
}

/// Хранит проекты как JSON-файлы в Application Support — исходные видео не трогаются.
final class ProjectStore: ProjectRepository, Sendable {
    let directories: ProjectDirectories

    private let baseDirectory: URL
    private let ioQueue = DispatchQueue(
        label: "ru.ungurenko.montazhka.project-store",
        qos: .userInitiated)

    var projectsDir: URL { directories.projects }
    var waveformsDir: URL { directories.waveforms }
    var enhancedAudioDir: URL { directories.enhancedAudio }
    var musicEQDir: URL { directories.musicEQ }
    var transcriptsDir: URL { directories.transcripts }
    var modelsDir: URL { directories.models }
    var shortsAnalysisDir: URL { directories.shortsAnalysis }

    init(baseDirectory: URL? = nil) {
        let base =
            baseDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Montazhka", isDirectory: true)
        self.baseDirectory = base
        directories = ProjectDirectories(
            projects: base.appendingPathComponent("Projects", isDirectory: true),
            waveforms: base.appendingPathComponent("Waveforms", isDirectory: true),
            enhancedAudio: base.appendingPathComponent("EnhancedAudio", isDirectory: true),
            musicEQ: base.appendingPathComponent("MusicEQ", isDirectory: true),
            transcripts: base.appendingPathComponent("Transcripts", isDirectory: true),
            models: base.appendingPathComponent("Models", isDirectory: true),
            shortsAnalysis: base.appendingPathComponent("ShortsAnalysis", isDirectory: true)
        )
        try? prepareDirectories()
    }

    private func fileURL(for id: UUID) -> URL {
        projectsDir.appendingPathComponent("\(id.uuidString).json")
    }

    private func metaURL(for id: UUID) -> URL {
        projectsDir.appendingPathComponent("\(id.uuidString).meta.json")
    }
    private func prepareDirectories() throws {
        do {
            try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: waveformsDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: enhancedAudioDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: musicEQDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: transcriptsDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: shortsAnalysisDir, withIntermediateDirectories: true)
        } catch {
            throw ProjectStoreError.prepareDirectory(String(reflecting: error))
        }
    }

    private func saveOnQueue(_ project: Project) throws {
        try prepareDirectories()
        var p = project
        p.schemaVersion = Project.currentSchemaVersion
        p.updatedAt = Date()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        do { data = try encoder.encode(p) } catch { throw ProjectStoreError.encode(String(reflecting: error)) }
        do { try data.write(to: fileURL(for: p.id), options: .atomic) } catch {
            throw ProjectStoreError.write(String(reflecting: error))
        }
        writeSidecarMeta(for: p)
    }

    /// Инвариант «meta на диске = соответствует текущему проекту»:
    /// не смогли записать свежую — убираем устаревшую, listProjects уйдёт
    /// в полный decode и карточка не соврёт.
    private func writeSidecarMeta(for project: Project) {
        let meta = ProjectSidecarMeta(
            schemaVersion: ProjectSidecarMeta.currentSchemaVersion,
            name: project.name,
            updatedAt: project.updatedAt,
            duration: project.totalDuration,
            clipCount: project.clips.count)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(meta).write(to: metaURL(for: project.id), options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: metaURL(for: project.id))
        }
    }

    private func loadOnQueue(id: UUID) throws -> Project {
        let data: Data
        do { data = try Data(contentsOf: fileURL(for: id)) } catch {
            throw ProjectStoreError.read(String(reflecting: error))
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(Project.self, from: data) } catch {
            throw ProjectStoreError.decode(String(reflecting: error))
        }
    }

    private func deleteOnQueue(id: UUID) throws {
        do { try FileManager.default.trashItem(at: fileURL(for: id), resultingItemURL: nil) } catch {
            throw ProjectStoreError.delete(String(reflecting: error))
        }
        // Метаданные карточки — best-effort: при отсутствии файла не мешаем удалению.
        try? FileManager.default.trashItem(at: metaURL(for: id), resultingItemURL: nil)
    }

    // MARK: - Последовательный интерфейс

    func save(_ project: Project) async throws {
        try await perform { try self.saveOnQueue(project) }
    }

    func load(id: UUID) async throws -> Project {
        try await perform { try self.loadOnQueue(id: id) }
    }

    func delete(id: UUID) async throws {
        try await perform { try self.deleteOnQueue(id: id) }
    }

    func listProjects() async throws -> ProjectListing {
        let directory = projectsDir
        return try await perform { try Self.listProjects(in: directory) }
    }

    func saveBeforeTermination(_ project: Project) throws {
        try ioQueue.sync { try saveOnQueue(project) }
    }

    private func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            ioQueue.async {
                continuation.resume(with: Result { try operation() })
            }
        }
    }

    /// Полная проверка каждого JSON выполняется вне главного потока.
    private static func listProjects(in directory: URL) throws -> ProjectListing {
        try Task.checkCancellation()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ProjectStoreError.prepareDirectory(String(reflecting: error))
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files: [URL]
        do { files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) } catch
        { throw ProjectStoreError.read(String(reflecting: error)) }
        var projects: [ProjectMeta] = []
        var issues: [ProjectListIssue] = []
        for url in files where url.pathExtension == "json" && !isSidecarMeta(url) {
            try Task.checkCancellation()
            if let projectID = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                let meta = try? decodeSidecarMeta(for: projectID, in: directory),
                meta.schemaVersion == ProjectSidecarMeta.currentSchemaVersion,
                meta.duration >= 0, meta.clipCount >= 0
            {
                projects.append(
                    ProjectMeta(
                        id: projectID, name: meta.name,
                        updatedAt: meta.updatedAt,
                        duration: meta.duration,
                        clipCount: meta.clipCount))
            } else {
                do {
                    let data = try Data(contentsOf: url)
                    let project = try decoder.decode(Project.self, from: data)
                    projects.append(
                        ProjectMeta(
                            id: project.id, name: project.name,
                            updatedAt: project.updatedAt,
                            duration: project.totalDuration,
                            clipCount: project.clips.count))
                } catch {
                    issues.append(
                        ProjectListIssue(
                            fileName: url.lastPathComponent,
                            message: String(reflecting: error)))
                }
            }
        }
        return ProjectListing(
            projects: projects.sorted { $0.updatedAt > $1.updatedAt },
            issues: issues)
    }

    private static func isSidecarMeta(_ url: URL) -> Bool {
        url.lastPathComponent.hasSuffix(".meta.json")
    }

    private static func decodeSidecarMeta(for id: UUID, in directory: URL) throws -> ProjectSidecarMeta {
        let url = directory.appendingPathComponent("\(id.uuidString).meta.json")
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ProjectSidecarMeta.self, from: data)
    }

    static func defaultProjectName() -> String {
        "Монтаж \(Date.now.formatted(.dateTime.day().month(.wide).locale(Locale(identifier: "ru_RU"))))"
    }
}
