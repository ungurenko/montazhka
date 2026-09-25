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

/// Единственная точка доступа к проектам. Все операции одного адаптера выполняются
/// последовательно; чтение видит все ранее запрошенные записи.
protocol ProjectRepository: Sendable {
    var directories: ProjectDirectories { get }

    func save(_ project: Project) async throws
    func load(id: UUID) async throws -> Project
    func delete(id: UUID) async throws
    func listProjects() async throws -> ProjectListing

    /// Синхронный финальный снимок для системного завершения приложения.
    func saveBeforeTermination(_ project: Project) throws

    /// Отметка версии файла проекта на диске. Меняется при каждой записи —
    /// и своей, и чужой (агент правит проект из другого процесса).
    /// nil — файла ещё нет или хранилище не на диске.
    func diskStamp(of id: UUID) -> Date?
}

extension ProjectRepository {
    func diskStamp(of id: UUID) -> Date? { nil }
}
