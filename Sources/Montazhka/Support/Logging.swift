import OSLog

extension Logger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "ru.ungurenko.montazhka"

    static let persistence = Logger(subsystem: subsystem, category: "persistence")
    static let export = Logger(subsystem: subsystem, category: "export")
    static let network = Logger(subsystem: subsystem, category: "network")
}
