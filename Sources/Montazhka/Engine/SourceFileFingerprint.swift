import Foundation

/// Общая часть ключей кэшей: путь, размер и время изменения исходного файла.
enum SourceFileFingerprint {
    static func key(for path: String) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(path)|\(size)|\(Int(mtime))"
    }
}
