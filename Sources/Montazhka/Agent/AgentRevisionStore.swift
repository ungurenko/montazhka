import Foundation

enum AgentRevisionError: LocalizedError {
    case nothingToUndo(requested: Int, available: Int)

    var errorDescription: String? {
        switch self {
        case .nothingToUndo(let requested, let available):
            "Нельзя отменить \(requested) шаг(ов): сохранено только \(available)."
        }
    }
}

/// Снимки проекта перед каждой правкой агента: `<base>/<projectId>/<n>.json`.
/// Номер ревизии — число сохранённых снимков, поэтому он переживает перезапуск.
actor AgentRevisionStore {
    let baseDirectory: URL

    init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    func revision(of projectID: UUID) -> Int {
        numbers(projectID).count
    }

    /// Сохраняет состояние ДО правки и возвращает новый номер ревизии.
    func push(_ project: Project) throws -> Int {
        let directory = self.directory(project.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let next = (numbers(project.id).last ?? 0) + 1
        try JSONEncoder().encode(project).write(
            to: directory.appendingPathComponent("\(next).json"), options: .atomic)
        return numbers(project.id).count
    }

    /// Проект на `steps` шагов назад. История не меняется, пока вызывающий
    /// не сохранит проект и не вызовет `drop`.
    func snapshot(projectID: UUID, steps: Int) throws -> Project {
        let available = numbers(projectID)
        guard steps >= 1, steps <= available.count else {
            throw AgentRevisionError.nothingToUndo(requested: steps, available: available.count)
        }
        let url = directory(projectID).appendingPathComponent("\(available[available.count - steps]).json")
        return try JSONDecoder().decode(Project.self, from: Data(contentsOf: url))
    }

    /// Забывает последние `steps` снимков — после успешной отмены
    /// или неудачного сохранения правки.
    func drop(projectID: UUID, steps: Int) {
        for number in numbers(projectID).suffix(steps) {
            try? FileManager.default.removeItem(
                at: directory(projectID).appendingPathComponent("\(number).json"))
        }
    }

    private func directory(_ projectID: UUID) -> URL {
        baseDirectory.appendingPathComponent(projectID.uuidString, isDirectory: true)
    }

    private func numbers(_ projectID: UUID) -> [Int] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory(projectID).path)) ?? []
        return names.compactMap { name in
            name.hasSuffix(".json") ? Int(name.dropLast(5)) : nil
        }.sorted()
    }
}
