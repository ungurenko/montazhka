import Foundation
import AVFoundation
import Speech
import CryptoKit

enum SpeechTranscriptionError: LocalizedError {
    case permissionDenied
    case unavailable
    case onDeviceUnavailable
    case noAudio
    case audioExtractionFailed
    case timedOut
    case recognitionFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Разреши распознавание речи в Системных настройках Mac."
        case .unavailable: return "Распознавание речи сейчас недоступно."
        case .onDeviceUnavailable: return "Для русского языка на этом Mac недоступно локальное распознавание речи."
        case .noAudio: return "В видео нет звуковой дорожки."
        case .audioExtractionFailed: return "Не удалось подготовить звук для распознавания."
        case .timedOut: return "Распознавание заняло слишком много времени. Попробуй разбить видео на части."
        case .recognitionFailed(let value): return "Не удалось распознать речь: \(value)"
        }
    }
}

struct SpeechChunk: Equatable, Sendable {
    let start: Double
    let duration: Double
}

enum SpeechChunkPlanner {
    static func make(duration: Double,
                     maximumDuration: Double = 50,
                     overlap: Double = 1) -> [SpeechChunk] {
        guard duration.isFinite, duration > 0, maximumDuration > 0 else { return [] }
        let safeOverlap = min(max(0, overlap), maximumDuration / 2)
        let step = maximumDuration - safeOverlap
        var chunks: [SpeechChunk] = []
        var start = 0.0
        while start < duration {
            let length = min(maximumDuration, duration - start)
            chunks.append(SpeechChunk(start: start, duration: length))
            guard start + length < duration else { break }
            start += step
        }
        return chunks
    }
}

enum SpeechTranscriber {
    static func transcribe(source: MediaReference, locale: Locale = Locale(identifier: "ru_RU")) async throws -> [TranscriptToken] {
        try await authorize()
        guard let sourceURL = source.resolvedURL else { throw SpeechTranscriptionError.unavailable }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw SpeechTranscriptionError.unavailable
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw SpeechTranscriptionError.onDeviceUnavailable
        }

        let asset = AVURLAsset(url: sourceURL)
        guard let duration = try? await asset.load(.duration).seconds,
              duration.isFinite, duration > 0 else {
            throw SpeechTranscriptionError.noAudio
        }
        let chunks = SpeechChunkPlanner.make(duration: duration)
        var allTokens: [TranscriptToken] = []
        for chunk in chunks {
            try Task.checkCancellation()
            let audioURL = try await extractAudio(from: asset, chunk: chunk)
            do {
                let tokens = try await recognize(audioURL: audioURL,
                                                 recognizer: recognizer,
                                                 sourceID: source.id,
                                                 timeOffset: chunk.start)
                allTokens.append(contentsOf: tokens)
                try? FileManager.default.removeItem(at: audioURL)
            } catch {
                try? FileManager.default.removeItem(at: audioURL)
                throw error
            }
        }
        return removingOverlapDuplicates(allTokens)
    }

    private static func authorize() async throws {
        var status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        }
        guard status == .authorized else { throw SpeechTranscriptionError.permissionDenied }
    }

    private static func extractAudio(from asset: AVURLAsset, chunk: SpeechChunk) async throws -> URL {
        guard (try? await asset.loadTracks(withMediaType: .audio).first) != nil else {
            throw SpeechTranscriptionError.noAudio
        }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-speech-\(UUID().uuidString).m4a")
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw SpeechTranscriptionError.audioExtractionFailed
        }
        session.outputURL = output
        session.outputFileType = .m4a
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: chunk.start, preferredTimescale: 600),
            duration: CMTime(seconds: chunk.duration, preferredTimescale: 600)
        )
        await session.export()
        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            throw SpeechTranscriptionError.audioExtractionFailed
        }
        return output
    }

    private static func recognize(audioURL: URL,
                                  recognizer: SFSpeechRecognizer,
                                  sourceID: UUID,
                                  timeOffset: Double) async throws -> [TranscriptToken] {
        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        let session = SpeechRecognitionSession(recognizer: recognizer,
                                               request: request,
                                               sourceID: sourceID,
                                               timeOffset: timeOffset)
        return try await withThrowingTaskGroup(of: [TranscriptToken].self) { group in
            group.addTask { try await session.run() }
            group.addTask {
                try await Task.sleep(nanoseconds: 60_000_000_000)
                throw SpeechTranscriptionError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw SpeechTranscriptionError.unavailable }
            return result
        }
    }

    private static func removingOverlapDuplicates(_ tokens: [TranscriptToken]) -> [TranscriptToken] {
        let sorted = tokens.sorted { $0.start < $1.start }
        var result: [TranscriptToken] = []
        for token in sorted {
            if let previous = result.last,
               abs(previous.start - token.start) <= 0.25,
               normalized(previous.text) == normalized(token.text) {
                if token.confidence > previous.confidence { result[result.count - 1] = token }
            } else {
                result.append(token)
            }
        }
        return result
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
    }
}

private final class SpeechRecognitionSession: @unchecked Sendable {
    private let lock = NSLock()
    private let recognizer: SFSpeechRecognizer
    private let request: SFSpeechURLRecognitionRequest
    private let sourceID: UUID
    private let timeOffset: Double
    private var task: SFSpeechRecognitionTask?
    private var continuation: CheckedContinuation<[TranscriptToken], Error>?
    private var finished = false

    init(recognizer: SFSpeechRecognizer, request: SFSpeechURLRecognitionRequest,
         sourceID: UUID, timeOffset: Double) {
        self.recognizer = recognizer
        self.request = request
        self.sourceID = sourceID
        self.timeOffset = timeOffset
    }

    func run() async throws -> [TranscriptToken] {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if finished {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                lock.unlock()
                let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                    guard let self else { return }
                    if let error {
                        self.finish(.failure(SpeechTranscriptionError.recognitionFailed(error.localizedDescription)))
                        return
                    }
                    guard let result, result.isFinal else { return }
                    let tokens = result.bestTranscription.segments.map { segment in
                        TranscriptToken(sourceID: self.sourceID,
                                        text: segment.substring,
                                        start: self.timeOffset + segment.timestamp,
                                        duration: segment.duration,
                                        confidence: segment.confidence)
                    }
                    self.finish(.success(tokens))
                }
                lock.lock()
                self.task = task
                lock.unlock()
            }
        }, onCancel: { [weak self] in
            self?.cancel()
        })
    }

    private func finish(_ result: Result<[TranscriptToken], Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = continuation
        self.continuation = nil
        task = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    private func cancel() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        let task = task
        lock.unlock()
        task?.cancel()
        finish(.failure(CancellationError()))
    }
}

/// Дисковый кэш расшифровки; повторный анализ того же файла не запускает Speech снова.
actor TranscriptStore {
    private let cacheDir: URL

    init(cacheDir: URL) {
        self.cacheDir = cacheDir
    }

    func ensure(source: MediaReference) async throws -> [TranscriptToken] {
        let url = cacheURL(for: source)
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: url),
           let cached = try? decoder.decode([TranscriptToken].self, from: data) {
            return cached.map {
                TranscriptToken(sourceID: source.id, text: $0.text, start: $0.start,
                                duration: $0.duration, confidence: $0.confidence)
            }
        }
        let tokens = try await SpeechTranscriber.transcribe(source: source)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(tokens)
        try data.write(to: url, options: .atomic)
        return tokens
    }

    private func cacheURL(for source: MediaReference) -> URL {
        let path = source.resolvedURL?.path ?? source.lastKnownPath
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? Int) ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "v1|ru_RU|\(path)|\(size)|\(Int(mtime))"
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDir.appendingPathComponent("\(hash).json")
    }
}
