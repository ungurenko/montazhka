@preconcurrency import AVFoundation
@preconcurrency import CoreML
import FluidAudio
import Foundation
import Vision

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
            let audio = FileManager.default.temporaryDirectory.appendingPathComponent(
                "montazhka-vad-\(UUID().uuidString).m4a")
            defer { try? FileManager.default.removeItem(at: audio) }
            guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                throw SpeechTranscriptionError.audioExtractionFailed
            }
            try await export.export(to: audio, as: .m4a)
            let samples = try AudioConverter().resampleAudioFile(audio)
            let enter = await manager.config.defaultThreshold
            speech = speechRuns(
                probabilities: try await manager.process(samples).map(\.probability),
                enter: enter, exit: enter - 0.15,
                duration: Double(samples.count) / Double(VadManager.sampleRate))
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
