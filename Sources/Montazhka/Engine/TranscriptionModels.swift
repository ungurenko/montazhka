import CryptoKit
import Foundation

struct TranscriptWord: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    let sourceID: UUID
    let text: String
    let start: Double
    let end: Double
    let confidence: Float

    var duration: Double { max(0, end - start) }

    init(
        id: UUID = UUID(), sourceID: UUID, text: String, start: Double,
        end: Double, confidence: Float
    ) {
        self.id = id
        self.sourceID = sourceID
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }

    init(
        id: UUID = UUID(), sourceID: UUID, text: String, start: Double,
        duration: Double, confidence: Float
    ) {
        self.init(
            id: id, sourceID: sourceID, text: text, start: start,
            end: start + duration, confidence: confidence)
    }
}

struct TranscriptDocument: Codable, Equatable, Sendable {
    static let currentVersion = 2

    let schemaVersion: Int
    let model: String
    let language: String
    let words: [TranscriptWord]

    init(words: [TranscriptWord]) {
        schemaVersion = Self.currentVersion
        model = "parakeet-tdt-0.6b-v3-int8"
        language = "ru"
        self.words = words
    }
}

actor TranscriptStore {
    private let cacheDir: URL
    private let transcriber: ParakeetTranscriber

    init(cacheDir: URL, modelsDir: URL) {
        self.cacheDir = cacheDir
        self.transcriber = ParakeetTranscriber(modelsDir: modelsDir)
    }

    func ensure(
        source: MediaReference,
        progress: (@Sendable (Double?) async -> Void)? = nil
    ) async throws -> [TranscriptWord] {
        let url = cacheURL(for: source)
        if let words = validatedCachedWords(source: source) { return words }
        let ownership = try await FileLock.acquire(guarding: url)
        defer { withExtendedLifetime(ownership) {} }
        if let words = validatedCachedWords(source: source) { return words }
        // A shared slot limits model/decode work across stores and worker processes.
        let slot = try await FileLock.acquireSlot(in: cacheDir, count: 2)
        defer { withExtendedLifetime(slot) {} }

        let words = try await transcriber.transcribe(source: source, progress: progress)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(TranscriptDocument(words: words))
        try data.write(to: url, options: .atomic)
        return words
    }

    func validatedCachedWords(source: MediaReference) -> [TranscriptWord]? {
        guard let words = TranscriptDocumentCache.shared.words(at: cacheURL(for: source), load: Self.validatedWords)
        else { return nil }
        return words.map {
            TranscriptWord(
                sourceID: source.id, text: $0.text, start: $0.start,
                end: $0.end, confidence: $0.confidence)
        }
    }

    func modelIsCached() async -> Bool {
        await transcriber.modelIsCached()
    }

    private static func validatedWords(at url: URL) -> [TranscriptWord]? {
        guard let document = try? JSONDecoder().decode(TranscriptDocument.self, from: Data(contentsOf: url)),
            document.schemaVersion == TranscriptDocument.currentVersion,
            document.model == "parakeet-tdt-0.6b-v3-int8", document.language == "ru",
            document.words.allSatisfy({
                $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start
                    && $0.confidence.isFinite
            })
        else { return nil }
        return document.words
    }

    static func cacheKey(for path: String) -> String {
        "v2|parakeet-tdt-0.6b-v3|ru|\(SourceFileFingerprint.key(for: path))"
    }

    func cacheURL(for source: MediaReference) -> URL {
        let path = source.resolvedURL?.path ?? source.lastKnownPath
        let key = Self.cacheKey(for: path)
        let hash = SHA256.hash(data: Data(key.utf8)).hex
        return cacheDir.appendingPathComponent("\(hash).json")
    }
}

/// Разобранные файлы расшифровок на весь процесс: агент читает одну и ту же расшифровку
/// десятки раз за сессию, а разбор JSON часовой записи стоит десятки миллисекунд.
/// Файл узнаётся по размеру, дате и номеру: запись идёт атомарной заменой файла,
/// поэтому новая расшифровка или правка руками никогда не отдаёт старые слова.
final class TranscriptDocumentCache: @unchecked Sendable {
    static let shared = TranscriptDocumentCache()
    /// Столько расшифровок держим: часовая запись — около 7.000 слов, ~1 МБ памяти.
    static let limit = 8

    private struct Identity: Equatable {
        let size: UInt64
        let modified: Date
        let file: UInt64
    }

    private let lock = NSLock()
    private var entries: [String: (identity: Identity, words: [TranscriptWord])] = [:]
    private var order: [String] = []

    /// nil — файла нет или он не прошёл проверку `load` (такой ответ не запоминается).
    func words(at url: URL, load: (URL) -> [TranscriptWord]?) -> [TranscriptWord]? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let identity = Identity(
            size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
            modified: attributes[.modificationDate] as? Date ?? .distantPast,
            file: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
        if let hit = lock.withLock({ entries[url.path] }), hit.identity == identity { return hit.words }
        guard let words = load(url) else { return nil }
        lock.withLock {
            if entries.updateValue((identity, words), forKey: url.path) == nil { order.append(url.path) }
            if order.count > Self.limit { entries[order.removeFirst()] = nil }
        }
        return words
    }
}
