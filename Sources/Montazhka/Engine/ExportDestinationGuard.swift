@preconcurrency import AVFoundation
import Foundation

/// Готовый файл лёг бы поверх того, из чего он собран.
struct ExportDestinationError: LocalizedError, Equatable, Sendable {
    let destination: String

    var errorDescription: String? {
        "Нельзя сохранить видео поверх файла, из которого оно собрано: \(destination)"
    }

    var recoverySuggestion: String? { "Выбери другое имя или другую папку." }
}

/// Назначение экспорта не совпадает ни с одним входом: ни по пути, ни через
/// символическую ссылку, ни жёсткой ссылкой на те же байты. Разрешение заменить
/// прошлый экспорт этой проверки не отменяет.
enum ExportDestinationGuard {
    static func check(_ destination: URL, inputs: [URL]) throws {
        let target = canonicalPath(destination)
        let targetFile = FileIdentity(destination)
        for input in inputs {
            let sameFile = targetFile != nil && FileIdentity(input) == targetFile
            if sameFile || canonicalPath(input) == target {
                throw ExportDestinationError(destination: destination.path)
            }
        }
    }

    /// Файлы, которые читают дорожки склейки: исходники, обработанный звук, анимации.
    static func compositionInputs(_ asset: AVAsset) -> [URL] {
        if let urlAsset = asset as? AVURLAsset { return [urlAsset.url] }
        guard let composition = asset as? AVComposition else { return [] }
        return composition.tracks.flatMap { track in track.segments.compactMap(\.sourceURL) }
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// Устройство и номер файла: одинаковы у пути, ссылки на него и жёсткой ссылки,
/// в том числе при другом регистре букв в имени. nil — файла нет.
private struct FileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t

    init?(_ url: URL) {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        device = info.st_dev
        inode = info.st_ino
    }
}

extension Project {
    /// Файлы, из которых собирается ролик: видео ленты, своя музыка, анимации.
    var exportInputFiles: [URL] {
        var files = clips.map(\.url)
        if let custom = music.customMedia { files.append(custom.fileURL) }
        files += overlays.map(\.media.fileURL)
        return files
    }
}

extension MediaReference {
    /// Где файл сейчас; пропавший — по последнему известному пути.
    fileprivate var fileURL: URL { resolvedURL ?? URL(fileURLWithPath: lastKnownPath) }
}
