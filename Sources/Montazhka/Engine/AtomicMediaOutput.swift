import Foundation

/// Безопасная запись медиафайла: незавершённый экспорт живёт во временном
/// файле рядом с назначением, а пользовательский файл заменяется только после успеха.
struct AtomicMediaOutput {
    let destinationURL: URL
    let temporaryURL: URL

    private let fileManager: FileManager
    private var committed = false

    init(destinationURL: URL, fileManager: FileManager = .default) {
        self.destinationURL = destinationURL
        self.fileManager = fileManager

        let directory = destinationURL.deletingLastPathComponent()
        let stem = destinationURL.deletingPathExtension().lastPathComponent
        let suffix = destinationURL.pathExtension
        let temporaryName =
            suffix.isEmpty
            ? ".\(stem).montazhka-\(UUID().uuidString)"
            : ".\(stem).montazhka-\(UUID().uuidString).\(suffix)"
        temporaryURL = directory.appendingPathComponent(temporaryName)
    }

    mutating func commit() throws {
        guard fileManager.fileExists(atPath: temporaryURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(
                destinationURL,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: [])
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        }
        committed = true
        removeLeftovers()
    }

    func discard() {
        guard !committed else { return }
        try? fileManager.removeItem(at: temporaryURL)
        removeLeftovers()
    }

    /// AVAssetWriter с оптимизацией под стриминг переписывает файл через свою
    /// копию рядом — «имя.mp4.sb-…» — и не всегда её убирает. Как только
    /// временный файл уезжает на место, копию уже никто не найдёт, поэтому
    /// сносим всё, что выросло из нашего имени. UUID в имени делает совпадение
    /// однозначным: чужие файлы под него не попадут.
    private func removeLeftovers() {
        let directory = temporaryURL.deletingLastPathComponent()
        let prefix = temporaryURL.lastPathComponent
        let names =
            (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name != prefix && name.hasPrefix(prefix) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
