import Foundation

struct ProjectDirectories: Sendable {
    let projects: URL
    let waveforms: URL
    let enhancedAudio: URL
    let musicEQ: URL
    let transcripts: URL
    let models: URL
    /// Результаты дорогих проходов ИИ по shorts: переживают перезапуск.
    let shortsAnalysis: URL
}

extension ProjectDirectories {
    /// Общая папка данных приложения (родитель папки проектов).
    private var base: URL { projects.deletingLastPathComponent() }
    /// Словарь терминов для расшифровок.
    var glossary: URL { base.appendingPathComponent("glossary.json") }
    /// Кэш найденных лиц для черновиков шортсов.
    var faceTracks: URL { base.appendingPathComponent("FaceTracks", isDirectory: true) }
    /// Файлы анимаций поверх видео (например, из HyperFrames).
    var overlays: URL { base.appendingPathComponent("Overlays", isDirectory: true) }
}

/// Версия файла проекта — отпечаток его байтов. Одинакова у записи и у чтения тех же
/// байтов, поэтому не зависит ни от часов, ни от отдельного `stat` после записи.
struct ProjectRevision: Hashable, Sendable {
    let digest: String
}

/// Единственная точка доступа к проектам. Все операции одного адаптера выполняются
/// последовательно; чтение видит все ранее запрошенные записи. Запись и удаление
/// файла проекта идут под общей межпроцессной блокировкой: окно, агент и другие
/// экземпляры хранилища не пишут его одновременно.
protocol ProjectRepository: Sendable {
    var directories: ProjectDirectories { get }

    /// Безусловная запись: новый проект или копия, у которых чужих версий нет.
    func save(_ project: Project) async throws
    /// Запись, только если на диске сейчас ровно `expected` (nil — файла ещё нет):
    /// сверка и запись — одна критическая секция. Иначе `ProjectStoreError.conflict`.
    /// Возвращает версию записанного файла.
    func save(_ project: Project, expected: ProjectRevision?) async throws -> ProjectRevision
    func load(id: UUID) async throws -> Project
    /// Содержимое и версия из одного и того же чтения.
    func loadWithRevision(id: UUID) async throws -> (project: Project, revision: ProjectRevision)
    func delete(id: UUID) async throws
    func listProjects() async throws -> ProjectListing

    /// Синхронный финальный снимок для системного завершения приложения — с той же сверкой.
    func saveBeforeTermination(_ project: Project, expected: ProjectRevision?) throws -> ProjectRevision

    /// Версия файла проекта на диске сейчас. nil — файла ещё нет или хранилище не на диске.
    func revision(of id: UUID) -> ProjectRevision?
}
