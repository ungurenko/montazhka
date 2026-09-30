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

    /// Отпечаток .srt, записанного рядом, — после отпечатка проекта.

    /// `subtitles` — `subtitlesDigest(_:)` того .srt, что ляжет рядом с файлом.
    static func metadataItems(
        fingerprint: String?, subtitles: String? = nil, previousSubtitles: String? = nil, ownerProjectID: UUID? = nil
    ) -> [AVMetadataItem] {
        guard fingerprint != nil || subtitles != nil || previousSubtitles != nil || ownerProjectID != nil else {
            return []
        }
        let item = AVMutableMetadataItem()
        item.identifier = .commonIdentifierDescription
        var fields = ["\(prefix)\(fingerprint ?? "")"]
        if let subtitles { fields.append("srt:\(subtitles)") }
        if let previousSubtitles { fields.append("previous-srt:\(previousSubtitles)") }
        if let ownerProjectID { fields.append("owner:\(ownerProjectID.uuidString)") }
        item.value = fields.joined(separator: " ") as NSString
        item.extendedLanguageTag = "und"
        return [item]
    }

    /// Отпечаток проекта; nil — отпечатка нет или файл не читается.
    static func read(url: URL) async -> String? {
        await stamp(url: url)?.project
    }

    /// Что записано в файл при экспорте; nil — файл не от Монтажки или не читается.
    static func stamp(url: URL) async -> ExportStamp? {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.metadata) else { return nil }
        for item in items {
            guard let value = try? await item.load(.stringValue), value.hasPrefix(prefix) else { continue }
            var stamp = ExportStamp(project: nil, subtitles: nil)
            for field in value.split(separator: " ") {
                if field.hasPrefix(prefix) {
                    let fingerprint = String(field.dropFirst(prefix.count))
                    stamp.project = fingerprint.isEmpty ? nil : fingerprint
                } else if field.hasPrefix("srt:") {
                    stamp.subtitles = String(field.dropFirst(4))
                } else if field.hasPrefix("previous-srt:") {
                    stamp.previousSubtitles = String(field.dropFirst(13))
                } else if field.hasPrefix("owner:") {
                    stamp.ownerProjectID = UUID(uuidString: String(field.dropFirst(6)))
                }
            }
            return stamp
        }
        return nil
    }

    /// Отпечаток содержимого .srt: по нему видно, что файл наш и его не правили.
    static func subtitlesDigest(_ data: Data) -> String {
        String(SHA256.hash(data: data).hex.prefix(16))
    }
}

/// Отметка готового MP4.
struct ExportStamp: Equatable, Sendable {
    /// `ExportProvenance.fingerprint(for:)`.
    var project: String?
    /// Отпечаток .srt, который экспорт положил рядом; nil — субтитров не было.
    var subtitles: String?
    var previousSubtitles: String? = nil
    var ownerProjectID: UUID? = nil
}
