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
        guard let document = try? load(from: cacheURL(for: source)),
            document.schemaVersion == TranscriptDocument.currentVersion,
            document.model == "parakeet-tdt-0.6b-v3-int8", document.language == "ru",
            document.words.allSatisfy({
                $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start
                    && $0.confidence.isFinite
            })
        else { return nil }
        return document.words.map {
            TranscriptWord(
                sourceID: source.id, text: $0.text, start: $0.start,
                end: $0.end, confidence: $0.confidence)
        }
    }

    func modelIsCached() async -> Bool {
        await transcriber.modelIsCached()
    }

    private func load(from url: URL) throws -> TranscriptDocument {
        try JSONDecoder().decode(TranscriptDocument.self, from: Data(contentsOf: url))
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
