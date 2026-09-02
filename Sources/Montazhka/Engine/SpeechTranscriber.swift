// Новые SDK строже аннотируют Sendable у AVFoundation-типов (например,
// результат loadTracks) — смягчаем до уровня предупреждений.
@preconcurrency import AVFoundation
import FluidAudio
import Foundation

enum SpeechTranscriptionError: LocalizedError {
    case unsupportedMac
    case noAudio
    case audioExtractionFailed
    case modelDownloadFailed
    case damagedModel
    case recognitionFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedMac:
            return "Умный монтаж работает на Mac с процессором Apple Silicon."
        case .noAudio:
            return "В видео нет звуковой дорожки."
        case .audioExtractionFailed:
            return "Не удалось подготовить звук для распознавания."
        case .modelDownloadFailed:
            return "Не удалось загрузить модель распознавания. Проверь интернет и попробуй ещё раз."
        case .damagedModel:
            return "Модель распознавания повреждена. Удали её в настройках и загрузи заново."
        case .recognitionFailed:
            return "Не получилось распознать речь."
        }
    }
}

actor ParakeetTranscriber {
    private let modelsDir: URL
    private var models: AsrModels?
    private var manager: AsrManager?

    init(modelsDir: URL) {
        self.modelsDir = modelsDir
    }

    func modelIsCached() -> Bool {
        AsrModels.modelsExist(at: modelsDir, version: .v3, encoderPrecision: .int8)
    }

    func transcribe(
        source: MediaReference,
        progress: (@Sendable (Double?) async -> Void)? = nil
    ) async throws -> [TranscriptWord] {
        #if !arch(arm64)
            throw SpeechTranscriptionError.unsupportedMac
        #else
            guard let sourceAccess = source.makeAccessLease() else {
                throw SpeechTranscriptionError.recognitionFailed("исходный файл недоступен")
            }
            let sourceURL = sourceAccess.url
            defer { withExtendedLifetime(sourceAccess) {} }
            let asr = try await ensureManager(progress: progress)
            try Task.checkCancellation()
            let audioURL = try await extractAudio(from: sourceURL)
            defer { try? FileManager.default.removeItem(at: audioURL) }

            do {
                let layers = await asr.decoderLayerCount
                var decoderState = TdtDecoderState.make(decoderLayers: layers)
                let result = try await asr.transcribe(
                    audioURL,
                    decoderState: &decoderState,
                    language: .russian)
                try Task.checkCancellation()
                return Self.makeWords(
                    sourceID: source.id,
                    tokenTimings: result.tokenTimings ?? [],
                    fallbackConfidence: result.confidence)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw SpeechTranscriptionError.recognitionFailed(String(reflecting: error))
            }
        #endif
    }

    private func ensureManager(progress: (@Sendable (Double?) async -> Void)?) async throws -> AsrManager {
        if let manager { return manager }
        let progressStream = AsyncStream.makeStream(
            of: Double?.self,
            bufferingPolicy: .bufferingNewest(1))
        let progressConsumer = Task {
            for await value in progressStream.stream {
                await progress?(value)
            }
        }
        do {
            try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
            let loaded = try await AsrModels.downloadAndLoad(
                to: modelsDir,
                version: .v3,
                encoderPrecision: .int8,
                progressHandler: { snapshot in
                    progressStream.continuation.yield(snapshot.fractionCompleted)
                }
            )
            try Task.checkCancellation()
            let config = ASRConfig(melChunkContext: false, dualDecodeArbitration: true)
            let manager = AsrManager(config: config)
            try await manager.loadModels(loaded)
            self.models = loaded
            self.manager = manager
            progressStream.continuation.yield(1)
            progressStream.continuation.finish()
            await progressConsumer.value
            return manager
        } catch is CancellationError {
            progressStream.continuation.finish()
            progressConsumer.cancel()
            await progressConsumer.value
            throw CancellationError()
        } catch let error as AsrModelsError {
            progressStream.continuation.finish()
            progressConsumer.cancel()
            await progressConsumer.value
            switch error {
            case .loadingFailed, .modelCompilationFailed, .modelNotFound:
                throw SpeechTranscriptionError.damagedModel
            case .downloadFailed:
                throw SpeechTranscriptionError.modelDownloadFailed
            }
        } catch {
            progressStream.continuation.finish()
            progressConsumer.cancel()
            await progressConsumer.value
            throw SpeechTranscriptionError.modelDownloadFailed
        }
    }

    private func extractAudio(from sourceURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        guard (try? await asset.loadTracks(withMediaType: .audio).first) != nil else {
            throw SpeechTranscriptionError.noAudio
        }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-parakeet-\(UUID().uuidString).m4a")
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw SpeechTranscriptionError.audioExtractionFailed
        }
        export.outputURL = output
        export.outputFileType = .m4a
        let cancellation = ExportSessionReference(export)
        await withTaskCancellationHandler(
            operation: {
                await export.export()
            },
            onCancel: {
                cancellation.value.cancelExport()
            })
        try Task.checkCancellation()
        guard export.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            throw SpeechTranscriptionError.audioExtractionFailed
        }
        return output
    }

    static func makeWords(
        sourceID: UUID,
        tokenTimings: [TokenTiming],
        fallbackConfidence: Float
    ) -> [TranscriptWord] {
        buildWordTimings(from: tokenTimings).map { word in
            let matching = tokenTimings.filter {
                $0.endTime > word.startTime && $0.startTime < word.endTime
            }
            let confidence =
                matching.isEmpty
                ? fallbackConfidence
                : matching.map(\.confidence).reduce(0, +) / Float(matching.count)
            return TranscriptWord(
                sourceID: sourceID,
                text: word.word,
                start: word.startTime,
                end: word.endTime,
                confidence: confidence)
        }
    }
}

private final class ExportSessionReference: @unchecked Sendable {
    let value: AVAssetExportSession
    init(_ value: AVAssetExportSession) { self.value = value }
}
