import CryptoKit
import Foundation

/// Результат дорогих проходов ИИ: карта видео и предложения по окнам.
/// Оба не зависят от запрошенного количества роликов, поэтому переживают
/// повторный запуск анализа с другими настройками отбора.
struct ShortsAnalysisCacheDocument: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let schemaVersion: Int
    let promptVersion: Int
    let videoMap: String
    let proposals: [ShortsProposalDTO]

    init(videoMap: String, proposals: [ShortsProposalDTO]) {
        schemaVersion = Self.currentVersion
        promptVersion = ShortsPrompts.version
        self.videoMap = videoMap
        self.proposals = proposals
    }
}

/// Дисковый кэш анализа shorts. Устроен как `TranscriptStore`: имя файла —
/// хэш всех входных данных, поэтому смена транскрипта, модели или промптов
/// автоматически даёт промах, а старые файлы просто перестают читаться.
actor ShortsAnalysisCache {
    private let cacheDir: URL

    init(cacheDir: URL) {
        self.cacheDir = cacheDir
    }

    func load(key: String) -> ShortsAnalysisCacheDocument? {
        guard
            let data = try? Data(contentsOf: url(for: key)),
            let document = try? JSONDecoder().decode(ShortsAnalysisCacheDocument.self, from: data),
            document.schemaVersion == ShortsAnalysisCacheDocument.currentVersion,
            document.promptVersion == ShortsPrompts.version
        else { return nil }
        return document
    }

    func store(_ document: ShortsAnalysisCacheDocument, key: String) {
        guard let data = try? JSONEncoder().encode(document) else { return }
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try? data.write(to: url(for: key), options: .atomic)
    }

    private func url(for key: String) -> URL {
        cacheDir.appendingPathComponent("\(key).json")
    }

    /// Ключ собирается из всего, что влияет на ответ модели: слов транскрипта,
    /// провайдера, модели, усилия рассуждения и версии промптов.
    static func key(
        words: [MappedTranscriptWord],
        configuration: AIRequestConfiguration
    ) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("v1|\(ShortsPrompts.version)".utf8))
        hasher.update(data: Data("|\(configuration.provider.rawValue)".utf8))
        hasher.update(data: Data("|\(configuration.modelID)".utf8))
        hasher.update(data: Data("|\(configuration.effort ?? "-")|".utf8))
        for word in words {
            hasher.update(
                data: Data(
                    "\(word.wordID)|\(word.text)|\(word.timelineStart)|\(word.timelineEnd);".utf8))
        }
        return hasher.finalize().hex
    }
}
