import Foundation
import OSLog

/// Уборка папки данных раз в сутки. Удаляет только то, что уже не нужно ни одному проекту:
/// копии анимаций и улучшенный голос, на которые никто не ссылается, законченные или брошенные фоновые
/// задачи старше двух недель, ревизии и заметки удалённых проектов, ревизии сверх
/// `revisionsKept`. Ничто моложе суток не трогается: так уборка не задевает правку агента,
/// которая идёт прямо сейчас. Расшифровки, волны и проекты не трогаются никогда.
enum StorageCleanup {
    static let interval: TimeInterval = 24 * 3600
    static let runsKeptFor: TimeInterval = 14 * 24 * 3600
    static let revisionsKept = 50

    struct Summary: Equatable {
        var files = 0
        var bytes: Int64 = 0
    }

    /// `base` — папка данных приложения. nil — уборка сегодня уже была или идёт в другом процессе.
    @discardableResult
    static func runIfDue(base: URL, now: Date = Date()) -> Summary? {
        guard let lock = try? FileLock(lockFile: base.appendingPathComponent("storage-cleanup.lock"), wait: false)
        else { return nil }
        defer { withExtendedLifetime(lock) {} }
        let marker = base.appendingPathComponent("last-cleanup")
        if let last = modified(marker), now.timeIntervalSince(last) < interval { return nil }
        let summary = run(base: base, now: now)
        FileManager.default.createFile(atPath: marker.path, contents: nil)
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: marker.path)
        Logger.persistence.info(
            "Уборка хранилища: удалено \(summary.files) файлов, \(summary.bytes / 1_000_000) МБ")
        return summary
    }

    static func run(base: URL, now: Date) -> Summary {
        let cutoff = now.addingTimeInterval(-interval)
        let projectFiles = contents(of: base.appendingPathComponent("Projects")).filter {
            $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".meta.json")
        }
        let liveProjects = Set(
            projectFiles.compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) })
        var summary = Summary()
        removeRevisions(in: base.appendingPathComponent("AgentRevisions"), live: liveProjects, cutoff: cutoff, &summary)
        for note in contents(of: base.appendingPathComponent("AgentNotes")) where note.pathExtension == "md" {
            guard let id = UUID(uuidString: note.deletingPathExtension().lastPathComponent), !liveProjects.contains(id),
                isOlder(note, than: cutoff)
            else { continue }
            remove(note, &summary)
        }
        let revisionFiles = contents(of: base.appendingPathComponent("AgentRevisions")).flatMap(contents(of:))
        removeOverlays(
            in: base.appendingPathComponent("Overlays"), referencedBy: projectFiles + revisionFiles, cutoff: cutoff,
            &summary)
        removeVoices(in: base.appendingPathComponent("EnhancedAudio"), projects: projectFiles, cutoff: cutoff, &summary)
        removeRuns(
            in: base.appendingPathComponent("AgentRuns"), olderThan: now.addingTimeInterval(-runsKeptFor), &summary)
        return summary
    }

    /// Ревизии удалённого проекта уходят целиком, у живого остаются `revisionsKept` последних.
    private static func removeRevisions(in directory: URL, live: Set<UUID>, cutoff: Date, _ summary: inout Summary) {
        for folder in contents(of: directory) {
            guard let id = UUID(uuidString: folder.lastPathComponent) else { continue }
            if !live.contains(id) {
                if isOlder(folder, than: cutoff) { remove(folder, &summary) }
                continue
            }
            let snapshots = contents(of: folder)
                .compactMap { file in
                    file.pathExtension == "json"
                        ? Int(file.deletingPathExtension().lastPathComponent).map { ($0, file) } : nil
                }
                .sorted { $0.0 < $1.0 }
            for (_, file) in snapshots.dropLast(revisionsKept) { remove(file, &summary) }
        }
    }

    /// Копия анимации нужна, пока её имя есть хоть в одном проекте или ревизии.
    private static func removeOverlays(
        in directory: URL, referencedBy documents: [URL], cutoff: Date, _ summary: inout Summary
    ) {
        let candidates = contents(of: directory).filter { isOlder($0, than: cutoff) }
        guard !candidates.isEmpty else { return }
        let texts = documents.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
        guard texts.count == documents.count else { return }  // не прочитали всё — не знаем, что нужно
        for file in candidates where !texts.contains(where: { $0.contains(file.lastPathComponent) }) {
            remove(file, &summary)
        }
    }

    /// Голос нужен, пока его исходник есть в клипах хоть одного проекта. Файл, который сейчас
    /// читает экспорт или предпросмотр, остаётся (`CacheFileLease`).
    private static func removeVoices(in directory: URL, projects: [URL], cutoff: Date, _ summary: inout Summary) {
        let candidates = contents(of: directory).filter { $0.pathExtension == "caf" && isOlder($0, than: cutoff) }
        guard !candidates.isEmpty else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var live = Set<String>()
        for url in projects {
            // Проект не прочитался — не знаем его исходников, поэтому голос не трогаем совсем.
            guard let data = try? Data(contentsOf: url), let project = try? decoder.decode(Project.self, from: data)
            else { return }
            for clip in project.clips {
                // Исходник на отключённом диске нельзя узнать по отпечатку: голос не трогаем совсем.
                if clip.sourcePath.hasPrefix("/Volumes/"), !FileManager.default.fileExists(atPath: clip.sourcePath) {
                    return
                }
                live.insert(VoiceEnhanceStore.sourceHash(for: clip.sourcePath))
            }
        }
        for file in candidates {
            let source = String(file.lastPathComponent.prefix { $0 != "-" })
            guard !live.contains(source) else { continue }
            let size = bytes(of: file)
            if CacheFileLease.removeIfUnused(file) {
                summary.files += 1
                summary.bytes += size
            }
        }
    }

    /// Задача старше срока, которую никто не выполняет: законченная или так и не получившая
    /// резов (`waitingForApproval`) — через две недели её расшифровка уже не пригодится.
    private static func removeRuns(in directory: URL, olderThan limit: Date, _ summary: inout Summary) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for folder in contents(of: directory) where UUID(uuidString: folder.lastPathComponent) != nil {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("run.json")),
                let run = try? decoder.decode(AgentRun.self, from: data),
                run.status.isFinished || run.status == .waitingForApproval, run.updatedAt < limit,
                !FileLock.isHeld(lockFile: folder.appendingPathComponent("worker.lock"))
            else { continue }
            remove(folder, &summary)
        }
    }

    private static func contents(of directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }

    private static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private static func isOlder(_ url: URL, than cutoff: Date) -> Bool {
        modified(url).map { $0 < cutoff } ?? false
    }

    private static func bytes(of url: URL) -> Int64 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else {
            return ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        }
        return contents(of: url).reduce(0) { $0 + bytes(of: $1) }
    }

    private static func remove(_ url: URL, _ summary: inout Summary) {
        let size = bytes(of: url)
        guard (try? FileManager.default.removeItem(at: url)) != nil else { return }
        summary.files += 1
        summary.bytes += size
    }
}
