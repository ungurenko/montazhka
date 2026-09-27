import CryptoKit
import Darwin
import Foundation

/// Кэш обработанного звука: один CAF на пару «исходник + настройки».
/// Обработка долгая, поэтому результат живёт на диске (как волны в WaveformStore).
/// Актор последовательно управляет общими рендерами своего экземпляра. Папку делят
/// окно и агент: у каждой обработки своя рабочая папка, готовый файл появляется
/// атомарным переименованием, а уборка не трогает файлы, которые держит склейка
/// (`CacheFileLease`). Диск остаётся источником правды.
actor VoiceEnhanceStore {
    private struct InFlight {
        let id: UUID
        let task: Task<URL, Error>
    }

    /// Рендер звука исходника в файл: `VoiceEnhancer.render`, в тестах — подмена.
    typealias Render =
        @Sendable (
            _ sourcePath: String, _ settings: VoiceEnhanceSettings, _ to: URL,
            _ isCancelled: @escaping @Sendable () -> Bool
        ) async throws -> Void

    private let cacheDir: URL
    private let render: Render
    private var inFlight: [String: InFlight] = [:]

    init(cacheDir: URL, render: @escaping Render = VoiceEnhancer.render) {
        self.cacheDir = cacheDir
        self.render = render
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
        let render = render
        let task = Task(priority: .userInitiated) {
            // Своя рабочая папка: ни второй экземпляр, ни отменённая, но ещё не убравшая
            // за собой прошлая обработка не пишут в те же файлы (и во внутренний .tmp рендера).
            let scratch = dir.appendingPathComponent(".work-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let working = scratch.appendingPathComponent("voice.caf")
            try await render(path, settings, working, { Task.isCancelled })
            if Task.isCancelled { throw CancellationError() }
            // Готовый файл появляется атомарно и никогда не подменяется: если сосед уже
            // выложил тот же вариант, его файл остаётся (его могут держать склейки), наш уходит.
            if renamex_np(working.path, url.path, UInt32(RENAME_EXCL)) != 0 {
                guard errno == EEXIST else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
                }
            }
            Self.evictOldVariants(dir: dir, sourceHash: sourceHash, keep: url)
            Self.removeStaleWorkFolders(dir: dir)
            return url
        }
        let operation = InFlight(id: UUID(), task: task)
        inFlight[key] = operation
        return operation
    }

    /// Отменяет все идущие рендеры (например, пока пользователь крутит ползунки).
    /// Отменённая обработка доубирает свою рабочую папку сама — новой она не мешает.
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

    /// Рабочая папка обработки, которую не убрали за сутки, осталась от упавшего процесса:
    /// обработка голоса идёт минуты, а не сутки.
    private static func removeStaleWorkFolders(dir: URL) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
        let dayAgo = Date().addingTimeInterval(-24 * 3600)
        for item in items where item.lastPathComponent.hasPrefix(".work-") {
            let modified = (try? item.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? Date()
            if modified < dayAgo { try? FileManager.default.removeItem(at: item) }
        }
    }

    /// Держим один вариант настроек на исходник — CAF большие. Вариант, который читает
    /// идущий экспорт или предпросмотр (в этом или другом процессе), остаётся до следующей уборки.
    private static func evictOldVariants(dir: URL, sourceHash: String, keep: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for file in files
        where file.lastPathComponent.hasPrefix("\(sourceHash)-")
            && file.pathExtension == "caf"
            && file.lastPathComponent != keep.lastPathComponent
        {
            CacheFileLease.removeIfUnused(file)
        }
    }
}
