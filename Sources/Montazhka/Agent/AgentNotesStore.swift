import Darwin
import Foundation

/// Заметки агента о проекте: бриф, стратегия, решения, просьбы, что осталось.
/// Пользователь их не видит. Файл `<base>/<projectId>.md` (UTF-8) лежит вне проекта,
/// поэтому окно Монтажки и `undo` его не трогают.
///
/// Актор упорядочивает вызовы только внутри процесса, а заметки одного проекта могут
/// одновременно писать `mcp` и разовые `agent`-процессы. Поэтому каждое
/// «прочитать → изменить → записать» идёт под межпроцессной блокировкой `<projectId>.md.lock`.
actor AgentNotesStore {
    /// Длиннее агенту неудобно читать за раз — пусть сожмёт заметки через `setNotes`.
    static let maxCharacters = 20_000

    let baseDirectory: URL

    init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    func read(_ projectID: UUID) -> String? {
        (try? existing(projectID)) ?? nil
    }

    /// Правка заметок: дописать под заголовком с датой или переписать целиком.
    enum Edit: Sendable, Equatable {
        /// "\n## yyyy-MM-dd HH:mm\n" + текст в конец.
        case append(String)
        /// Весь текст; пустой (или одни пробелы) очищает заметки.
        case replace(String)
    }

    /// Дописывает заметку под заголовком с датой: "\n## yyyy-MM-dd HH:mm\n" + текст.
    func append(_ projectID: UUID, text: String, at date: Date) throws {
        try apply(projectID, [.append(text)], at: date)
    }

    /// Переписывает заметки целиком. Пустой текст (или одни пробелы) удаляет файл.
    func replace(_ projectID: UUID, text: String) throws {
        try apply(projectID, [.replace(text)], at: Date())
    }

    /// Правки одной пачки: применяются к тексту в памяти по порядку, длина проверяется
    /// один раз по итогу, файл пишется один раз под блокировкой — либо все правки, либо
    /// ни одной. Итог из одних пробелов удаляет файл.
    func apply(_ projectID: UUID, _ edits: [Edit], at date: Date) throws {
        try locked(projectID) {
            var text = try existing(projectID) ?? ""
            for edit in edits {
                switch edit {
                case .append(let note):
                    text += "\n## \(Self.stamp(date))\n" + note
                case .replace(let whole):
                    text = whole.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : whole
                }
            }
            guard !text.isEmpty else {
                let url = fileURL(projectID)
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                return
            }
            try write(projectID, text)
        }
    }

    /// Заметки для копии проекта: строка `header`, под ней заметки источника. Если у получателя
    /// уже есть заметки, они остаются выше. Нет заметок у источника — ничего не делает.
    /// Лимит здесь не проверяется: копия проекта не должна ломаться из-за длины заметок,
    /// а следующая запись попросит агента их сжать.
    func copy(from source: UUID, to destination: UUID, header: String) throws {
        guard let notes = try existing(source) else { return }
        let block = header + "\n" + notes
        try locked(destination) {
            try save(destination, try existing(destination).map { $0 + "\n" + block } ?? block)
        }
    }

    /// Держит блокировку `<projectId>.md.lock` (flock, с ожиданием) на время `body`.
    /// `body` синхронный, поэтому блокировка никогда не переживает `await`. Файл блокировки
    /// не удаляется: иначе другой процесс мог бы заблокировать новый файл с тем же именем.
    private func locked<T>(_ projectID: UUID, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let descriptor = Darwin.open(fileURL(projectID).path + ".lock", O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    /// Текст заметок; nil — файла нет. Нечитаемый файл — ошибка, а не пустые заметки,
    /// чтобы запись поверх не стёрла его молча.
    private func existing(_ projectID: UUID) throws -> String? {
        let url = fileURL(projectID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func write(_ projectID: UUID, _ text: String) throws {
        guard text.count <= Self.maxCharacters else {
            throw AgentServiceError.invalidInput(
                "Заметки проекта длиннее \(Self.maxCharacters) знаков (получилось бы \(text.count)). "
                    + "Сожмите их: перепишите целиком операцией setNotes.")
        }
        try save(projectID, text)
    }

    private func save(_ projectID: UUID, _ text: String) throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: fileURL(projectID), options: .atomic)
    }

    private func fileURL(_ projectID: UUID) -> URL {
        baseDirectory.appendingPathComponent("\(projectID.uuidString).md")
    }

    /// Время заголовка в календаре и часовом поясе пользователя, формат фиксирован.
    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar.current
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
