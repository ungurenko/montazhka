import Foundation

/// Какая сборка Монтажки отвечает агенту. MCP-сервер живёт столько же,
/// сколько сессия агента, и после установки новой версии продолжает работать
/// старым кодом — это надо уметь заметить.
enum AgentBuildInfo {
    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info["CFBundleVersion"] as? String ?? "0"
        let commit = (info["MontazhkaCommit"] as? String).map { " \($0)" } ?? ""
        return "\(short) (\(build))\(commit)"
    }

    /// Дата изменения исполняемого файла: меняется, когда приложение переустановили.
    static func executableStamp() -> Date? {
        guard let path = Bundle.main.executableURL?.path else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    static let staleWarning =
        "Монтажка обновилась после старта этой сессии: сервер работает старым кодом. "
        + "Попросите пользователя перезапустить сессию агента."
}
