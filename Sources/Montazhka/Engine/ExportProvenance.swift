@preconcurrency import AVFoundation
import CryptoKit
import Foundation

/// Из какой версии проекта собран готовый MP4: отпечаток `fingerprint(for:)`
/// лежит в метаданных самого файла. Проверка готового файла сверяет его
/// с проектом и видит, что файл устарел после правок.
enum ExportProvenance {
    /// Описание файла вида `montazhka-project:<отпечаток>` — AVFoundation
    /// сохраняет его в MP4 на обоих путях записи.
    private static let prefix = "montazhka-project:"

    /// Всё, из чего собирается файл: лента, анимации, настройки экспорта, музыка,
    /// улучшение голоса, оформление черновика шортса.
    private struct Shape: Encodable {
        let clips: [Clip]
        let overlays: [ProjectOverlay]
        let export: ExportPreferences
        let music: MusicSettings
        let voiceEnhance: VoiceEnhanceSettings
        let shorts: ShortsPresentation?
    }

    /// Отпечаток сохранённой версии проекта. Имя, даты, поиск пауз и путь MP4
    /// черновика в него не входят: файл от них не меняется. Разовые параметры
    /// экспорта агента тоже не входят — файл всё равно собран из этой версии.
    /// Отпечаток ленты для номеров слов — другой: `AgentWordCuts.fingerprint`.
    static func fingerprint(for project: Project) -> String {
        var shorts = project.shorts
        shorts?.exportPath = nil
        let shape = Shape(
            clips: project.clips, overlays: project.overlays, export: project.export, music: project.music,
            voiceEnhance: project.voiceEnhance, shorts: shorts)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        let data = (try? encoder.encode(shape)) ?? Data()
        return String(SHA256.hash(data: data).hex.prefix(16))
    }

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
