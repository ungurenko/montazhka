import CryptoKit
import Foundation

/// Кэш обработанного звука: один CAF на пару «исходник + настройки».
/// Обработка долгая, поэтому результат живёт на диске (как волны в WaveformStore).
/// Актор последовательно управляет общими рендерами; готовые файлы появляются
/// атомарно (рендер в .work + moveItem), диск остаётся источником правды.
actor VoiceEnhanceStore {
    private struct InFlight {
        let id: UUID
        let task: Task<URL, Error>
    }

    private let cacheDir: URL
    private var inFlight: [String: InFlight] = [:]

    init(cacheDir: URL) {
        self.cacheDir = cacheDir
    }

    /// Мгновенно: URL готового файла или nil, если ещё не обработан.
    func readyURL(source path: String, settings: VoiceEnhanceSettings) -> URL? {
        let url = cacheFileURL(source: path, settings: settings)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Гарантирует готовый обработанный файл (из кэша или новым рендером).
    func ensure(source path: String, settings: VoiceEnhanceSettings) async throws -> URL {
        let url = cacheFileURL(source: path, settings: settings)
        if FileManager.default.fileExists(atPath: url.path) { return url }

        let key = url.lastPathComponent
        let operation = renderTask(key: key, url: url, path: path, settings: settings)
        defer {
            if inFlight[key]?.id == operation.id { inFlight[key] = nil }
        }
        return try await operation.task.value
    }

    /// Возвращает идущий рендер или запускает новый (потокобезопасно).
    private func renderTask(
        key: String, url: URL, path: String,
        settings: VoiceEnhanceSettings
    ) -> InFlight {
        if let existing = inFlight[key] { return existing }
        let sourceHash = Self.sourceHash(for: path)
        let dir = cacheDir
        let task = Task(priority: .userInitiated) {
            let working = url.deletingPathExtension().appendingPathExtension("work.caf")
            defer { try? FileManager.default.removeItem(at: working) }
            try await VoiceEnhancer.render(
                sourcePath: path, settings: settings,
                to: working, isCancelled: { Task.isCancelled })
            if Task.isCancelled { throw CancellationError() }
            // Готовый файл появляется атомарно — отменённый рендер не оставит битого кэша.
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: working, to: url)
            Self.evictOldVariants(dir: dir, sourceHash: sourceHash, keep: url)
            return url
        }
        let operation = InFlight(id: UUID(), task: task)
        inFlight[key] = operation
        return operation
    }

    /// Отменяет все идущие рендеры (например, пока пользователь крутит ползунки).
    func cancelAll() {
        for operation in inFlight.values { operation.task.cancel() }
        inFlight.removeAll()
    }

    // MARK: - Имена и уборка

    private func cacheFileURL(source path: String, settings: VoiceEnhanceSettings) -> URL {
        let settingsHash = Self.hash(settings.cacheKey)
        return cacheDir.appendingPathComponent("\(Self.sourceHash(for: path))-\(settingsHash).caf")
    }

    private static func sourceHash(for path: String) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? Int) ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return hash("\(path)|\(size)|\(Int(mtime))")
    }

    private static func hash(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).hex
    }

    /// Держим только один вариант настроек на исходник — CAF большие.
    private static func evictOldVariants(dir: URL, sourceHash: String, keep: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for file in files
        where file.lastPathComponent.hasPrefix("\(sourceHash)-")
            && file.pathExtension == "caf"
            && !file.lastPathComponent.contains(".work")
            && !file.lastPathComponent.contains(".tmp")
            && file.lastPathComponent != keep.lastPathComponent
        {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
