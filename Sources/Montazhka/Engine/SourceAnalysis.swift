@preconcurrency import AVFoundation
@preconcurrency import CoreML
import FluidAudio
import Foundation
import Vision
import os

/// Дополнительная защита речи и кандидаты приватности. Границы VAD не являются резами.
/// Сырые строки OCR никогда не попадают в JSON или stdout.
enum SourceAnalysis {
    struct Finding: Codable, Sendable {
        let time: Double
        let kind: String
        let confidence: Float
        /// Координаты Vision: нормализованные, начало снизу слева.
        let box: [Double]
    }

    struct Report: Codable, Sendable {
        let version: Int
        let vadModel: String?
        /// Шаг модели VAD, с: границы `speech` лежат на этой сетке исходника.
        let vadFrame: Double?
        let speech: [[Double]]
        let ocrFindings: [Finding]
        let ocrSampleTimes: [Double]
        let privacyStatus: String
    }

    /// Отрезки речи для защиты пауз: подряд идущие куски модели (по 256 мс) с речью, без запаса и без
    /// принудительной нарезки. `segmentSpeech` FluidAudio по умолчанию готовит куски для расшифровки:
    /// тишина короче 0,75 с остаётся внутри речи, блоки режутся по 14 с — паузы так не видны.
    static let vadModel = "silero-vad-v6.2.1/FluidAudio-0.15.5/pause-chunks-v1"
    static let vadFrame = Double(VadManager.chunkSize) / Double(VadManager.sampleRate)

    /// Речь начинается с куска, где вероятность ≥ enter, и заканчивается перед первым куском < exit
    /// (гистерезис Silero). Один тихий кусок уже разрывает речь.
    static func speechRuns(probabilities: [Float], enter: Float, exit: Float, duration: Double) -> [[Double]] {
        func time(_ index: Int) -> Double { Double(index * VadManager.chunkSize) / Double(VadManager.sampleRate) }
        var runs: [[Double]] = []
        var start: Int?
        for (index, probability) in probabilities.enumerated() {
            if start == nil, probability >= enter {
                start = index
            } else if let first = start, probability < exit {
                runs.append([time(first), time(index)])
                start = nil
            }
        }
        if let first = start { runs.append([time(first), time(probabilities.count)]) }
        return runs.compactMap { run in
            let end = min(run[1], duration)
            return end > run[0] ? [run[0], end] : nil
        }
    }

    static func privacyKind(_ text: String) -> String? {
        let patterns = [
            (
                "credential",
                #"(?i)(sk-[a-z0-9_-]{12,}|[0-9]{6,}:[a-z0-9_-]{20,}|(?:api[_ -]?key|secret|password|token)\s*[:=]\s*\S{6,})"#
            ),
            ("email", #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#),
            ("identifier", #"\b[0-9]{9,16}\b"#),
        ]
        return patterns.first { text.range(of: $0.1, options: .regularExpression) != nil }?.0
    }

    /// Звук всех дорожек читается кусками на родной частоте и одним непрерывным конвертером
    /// переводится в 16 кГц моно — как делал `AudioConverter` FluidAudio, но без всей дорожки
    /// в памяти. Встроенный в чтение пересчёт частоты не годится: от запуска к запуску он даёт
    /// разное число сэмплов. В VAD звук уходит кусками по 4096 сэмплов с переносом состояния
    /// модели, как в `VadManager.process`. Возвращает вероятность речи на кусок и число сэмплов.
    private static func speechProbabilities(
        asset: AVURLAsset, manager: VadManager
    ) async throws -> (probabilities: [Float], samples: Int) {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty,
            let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Double(VadManager.sampleRate), channels: 1,
                interleaved: false),
            let resampled = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 65_536)
        else { throw SpeechTranscriptionError.audioExtractionFailed }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let output: AVAssetReaderOutput =
            tracks.count == 1
            ? AVAssetReaderTrackOutput(track: tracks[0], outputSettings: settings)
            : AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        guard reader.canAdd(output) else { throw SpeechTranscriptionError.audioExtractionFailed }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? SpeechTranscriptionError.audioExtractionFailed }
        defer { reader.cancelReading() }

        var converter: AVAudioConverter?
        var state = await manager.makeStreamState()
        var probabilities: [Float] = []
        var chunk: [Float] = []
        chunk.reserveCapacity(VadManager.chunkSize)
        var total = 0

        /// Переводит `input` (nil — конец звука) и отдаёт готовые сэмплы в VAD.
        func convert(_ input: AVAudioPCMBuffer?, with converter: AVAudioConverter) async throws {
            nonisolated(unsafe) let input = input
            let given = OSAllocatedUnfairLock(initialState: false)
            while true {
                resampled.frameLength = 0
                var error: NSError?
                let status = converter.convert(to: resampled, error: &error) { _, inputStatus in
                    guard let input,
                        !given.withLock({ wasGiven in
                            defer { wasGiven = true }; return wasGiven
                        })
                    else {
                        inputStatus.pointee = input == nil ? .endOfStream : .noDataNow
                        return nil
                    }
                    inputStatus.pointee = .haveData
                    return input
                }
                guard status != .error else { throw error ?? SpeechTranscriptionError.audioExtractionFailed }
                let samples = UnsafeBufferPointer(
                    start: resampled.floatChannelData![0], count: Int(resampled.frameLength))
                total += samples.count
                var offset = 0
                while offset < samples.count {
                    let take = min(VadManager.chunkSize - chunk.count, samples.count - offset)
                    chunk += samples[offset..<(offset + take)]
                    offset += take
                    guard chunk.count == VadManager.chunkSize else { continue }
                    let result = try await manager.processStreamingChunk(chunk, state: state)
                    probabilities.append(result.probability)
                    state = result.state
                    chunk.removeAll(keepingCapacity: true)
                }
                guard status == .haveData else { return }
            }
        }

        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let frames = CMSampleBufferGetNumSamples(sample)
            guard frames > 0 else { continue }
            // Больше двух каналов без раскладки AVAudioFormat не принимает: тогда каналы
            // считаются просто по порядку. Пропускать кусок нельзя — сместилось бы время речи.
            guard let description = CMSampleBufferGetFormatDescription(sample),
                let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description),
                let layout = CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: nil)
                    .map({ AVAudioChannelLayout(layout: $0) })
                    ?? AVAudioChannelLayout(
                        layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | stream.pointee.mChannelsPerFrame),
                let format = AVAudioFormat(streamDescription: stream, channelLayout: layout),
                let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
            else { throw SpeechTranscriptionError.audioExtractionFailed }
            input.frameLength = AVAudioFrameCount(frames)
            guard
                CMSampleBufferCopyPCMDataIntoAudioBufferList(
                    sample, at: 0, frameCount: Int32(frames), into: input.mutableAudioBufferList) == noErr
            else { throw SpeechTranscriptionError.audioExtractionFailed }
            if converter == nil {
                converter = AVAudioConverter(from: format, to: target)
                // Стерео в моно конвертер сам сводит к первому каналу; для каналов «по порядку»
                // своего правила у него нет, и без явной карты он отдаёт тишину.
                if format.channelCount > 2 { converter?.channelMap = [0] }
            }
            guard let converter else { throw SpeechTranscriptionError.audioExtractionFailed }
            try await convert(input, with: converter)
        }
        guard reader.status == .completed else { throw reader.error ?? SpeechTranscriptionError.audioExtractionFailed }
        if let converter { try await convert(nil, with: converter) }
        // Последний неполный кусок модель дополняет сама, как в `VadManager.process`.
        if !chunk.isEmpty {
            probabilities.append(try await manager.processStreamingChunk(chunk, state: state).probability)
        }
        return (probabilities, total)
    }

    static func run(file: URL, output: URL, vad: Bool, ocr: Bool, confirmDownload: Bool) async throws {
        guard file.standardizedFileURL != output.standardizedFileURL else {
            throw AgentServiceError.invalidInput("Анализ нельзя записать поверх исходника.")
        }
        let asset = AVURLAsset(url: file)
        let duration = try await asset.load(.duration).seconds
        var speech: [[Double]] = []
        if vad {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("FluidAudio")
            let models = base.appendingPathComponent("Models")
            let candidates = [
                models.appendingPathComponent(ModelNames.VAD.sileroVadFile),
                // Сюда кладёт модель сам FluidAudio (`--confirm-model-download`).
                models.appendingPathComponent(Repo.vad.folderName).appendingPathComponent(ModelNames.VAD.sileroVadFile),
                models.appendingPathComponent("silero-vad-coreml").appendingPathComponent(ModelNames.VAD.sileroVadFile),
            ]
            let manager: VadManager
            if let cached = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                let config = MLModelConfiguration()
                config.computeUnits = .all
                manager = VadManager(vadModel: try MLModel(contentsOf: cached, configuration: config))
            } else {
                guard confirmDownload else {
                    throw AgentServiceError.invalidInput(
                        "VAD не установлен: analyze-source --vad --confirm-model-download для первого запуска.")
                }
                manager = try await VadManager(modelDirectory: base)
            }
            let (probabilities, samples) = try await speechProbabilities(asset: asset, manager: manager)
            let enter = await manager.config.defaultThreshold
            speech = speechRuns(
                probabilities: probabilities, enter: enter, exit: enter - 0.15,
                duration: Double(samples) / Double(VadManager.sampleRate))
        }
        var findings: [Finding] = []
        var sampled: [Double] = []
        if ocr {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1920, height: 1080)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            for time in stride(from: 0.0, to: duration, by: 15) {
                try Task.checkCancellation()
                let image = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["ru-RU", "en-US"]
                try VNImageRequestHandler(cgImage: image).perform([request])
                sampled.append(time)
                for observation in request.results ?? [] {
                    guard let candidate = observation.topCandidates(1).first,
                        let kind = privacyKind(candidate.string)
                    else { continue }
                    let box = observation.boundingBox
                    findings.append(
                        Finding(
                            time: time, kind: kind, confidence: candidate.confidence,
                            box: [box.minX, box.minY, box.width, box.height]))
                }
            }
        }
        let report = Report(
            version: 1, vadModel: vad ? vadModel : nil, vadFrame: vad ? vadFrame : nil,
            speech: speech, ocrFindings: findings, ocrSampleTimes: sampled,
            privacyStatus: ocr ? "sampled-requires-review" : "not-checked")
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(report).write(to: output, options: .atomic)
    }
}
