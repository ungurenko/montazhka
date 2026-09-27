@preconcurrency import AVFoundation
import Foundation

/// Из какой ленты собран готовый MP4: отпечаток `AgentWordCuts.fingerprint`
/// лежит в метаданных самого файла. Проверка готового файла сверяет его
/// с проектом и видит, что файл устарел после правок.
enum ExportProvenance {
    /// Описание файла вида `montazhka-timeline:<отпечаток>` — AVFoundation
    /// сохраняет его в MP4 на обоих путях записи.
    private static let prefix = "montazhka-timeline:"

    static func metadataItems(fingerprint: String) -> [AVMetadataItem] {
        let item = AVMutableMetadataItem()
        item.identifier = .commonIdentifierDescription
        item.value = "\(prefix)\(fingerprint)" as NSString
        item.extendedLanguageTag = "und"
        return [item]
    }

    /// nil — отпечатка нет или файл не читается.
    static func read(url: URL) async -> String? {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.metadata) else { return nil }
        for item in items {
            guard let value = try? await item.load(.stringValue), value.hasPrefix(prefix) else { continue }
            return String(value.dropFirst(prefix.count))
        }
        return nil
    }
}
