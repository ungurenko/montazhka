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

/// Совместимость с прежней локальной моделью слов на время миграции панели.
typealias TranscriptToken = TranscriptWord

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
        progress: (@Sendable (Double?) -> Void)? = nil
    ) async throws -> [TranscriptWord] {
        let url = cacheURL(for: source)
        if let document = try? load(from: url),
            document.schemaVersion == TranscriptDocument.currentVersion,
            document.model == "parakeet-tdt-0.6b-v3-int8",
            document.language == "ru"
        {
            return document.words.map {
                TranscriptWord(
                    sourceID: source.id, text: $0.text, start: $0.start,
                    end: $0.end, confidence: $0.confidence)
            }
        }

        let words = try await transcriber.transcribe(source: source, progress: progress)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(TranscriptDocument(words: words))
        try data.write(to: url, options: .atomic)
        return words
    }

    func modelIsCached() async -> Bool {
        await transcriber.modelIsCached()
    }

    private func load(from url: URL) throws -> TranscriptDocument {
        try JSONDecoder().decode(TranscriptDocument.self, from: Data(contentsOf: url))
    }

    func cacheURL(for source: MediaReference) -> URL {
        let path = source.resolvedURL?.path ?? source.lastKnownPath
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "v2|parakeet-tdt-0.6b-v3|ru|\(path)|\(size)|\(Int(mtime))"
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDir.appendingPathComponent("\(hash).json")
    }
}
