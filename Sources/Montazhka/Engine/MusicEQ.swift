import Foundation
import AVFoundation
import CryptoKit

/// Оффлайн-эквалайзер фоновой музыки: освобождает место для голоса.
/// По практикам сведения речи с музыкой: срез гула снизу, лёгкий срез
/// «каши» на 250 Гц, заметный срез зоны разборчивости речи (1–4 кГц)
/// и приглушение верхов, чтобы музыка не спорила с согласными.
/// Только срезы — громкость музыки не растёт, клиппинг невозможен.
enum MusicEQ {
    /// Версия обработки — при изменении частот кэш пересчитается сам.
    static let cacheKey = "musiceq-v1"

    /// Синхронная работа с диском и движком — звать из Task.detached.
    static func render(sourcePath: String, to outURL: URL, isCancelled: () -> Bool) throws {
        let asset = AVURLAsset(url: URL(fileURLWithPath: sourcePath))
        guard let track = VoiceEnhancer.loadAudioTrackSync(asset) else { throw VoiceEnhanceError.noAudioTrack }
        let (sampleRate, sourceChannels) = VoiceEnhancer.pcmInfo(of: track, asset: asset)
        let channels = AVAudioChannelCount(min(2, max(1, sourceChannels)))

        guard let reader = try? AVAssetReader(asset: asset) else { throw VoiceEnhanceError.readerFailed }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channels),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw VoiceEnhanceError.readerFailed }
        reader.add(output)
        guard reader.startReading() else { throw VoiceEnhanceError.readerFailed }
        defer { reader.cancelReading() }

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)
        else { throw VoiceEnhanceError.engineFailed }

        let feeder = ReaderFeeder(reader: reader, output: output, channels: Int(channels))
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, abl in
            feeder.fill(frameCount: frameCount, abl: abl)
            return noErr
        }

        let eq = AVAudioUnitEQ(numberOfBands: 4)
        configureEQ(eq)

        let engine = AVAudioEngine()
        engine.attach(source)
        engine.attach(eq)
        engine.connect(source, to: eq, format: format)
        engine.connect(eq, to: engine.mainMixerNode, format: format)

        do {
            try engine.enableManualRenderingMode(.offline, format: format,
                                                 maximumFrameCount: 4096)
            try engine.start()
        } catch {
            throw VoiceEnhanceError.engineFailed
        }
        defer { engine.stop() }

        try? FileManager.default.removeItem(at: outURL)
        let outFile = try AVAudioFile(forWriting: outURL, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channels),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ], commonFormat: .pcmFormatFloat32, interleaved: false)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                            frameCapacity: 4096)
        else { throw VoiceEnhanceError.engineFailed }

        var framesWritten: AVAudioFramePosition = 0
        renderLoop: while true {
            if isCancelled() { throw CancellationError() }
            let status = try engine.renderOffline(4096, to: buffer)
            switch status {
            case .success:
                // Обрезаем хвостовые нули: пишем не больше, чем реально пришло из исходника.
                let served = feeder.framesServed
                let real = min(AVAudioFramePosition(buffer.frameLength), served - framesWritten)
                if real <= 0 {
                    if feeder.isExhausted { break renderLoop }
                    continue
                }
                buffer.frameLength = AVAudioFrameCount(real)
                try outFile.write(from: buffer)
                framesWritten += real
                if feeder.isExhausted && framesWritten >= served { break renderLoop }
            case .insufficientDataFromInputNode:
                continue
            default:
                throw VoiceEnhanceError.renderFailed
            }
        }
        guard framesWritten > 0 else { throw VoiceEnhanceError.noAudioTrack }
    }

    private static func configureEQ(_ eq: AVAudioUnitEQ) {
        // Срез суб-баса: гул не помогает музыке, но маскирует низ голоса.
        eq.bands[0].filterType = .highPass
        eq.bands[0].frequency = 100
        eq.bands[0].bandwidth = 0.5
        eq.bands[0].bypass = false

        // Низ-середина 250 Гц: убираем «кашу» под фундаментом голоса.
        eq.bands[1].filterType = .parametric
        eq.bands[1].frequency = 250
        eq.bands[1].bandwidth = 1.0
        eq.bands[1].gain = -3
        eq.bands[1].bypass = false

        // Зона разборчивости речи 1–4 кГц: главный срез, широкий и мягкий.
        eq.bands[2].filterType = .parametric
        eq.bands[2].frequency = 2500
        eq.bands[2].bandwidth = 1.3
        eq.bands[2].gain = -5
        eq.bands[2].bypass = false

        // Верха от 8 кГц: не спорим со свистящими и «воздухом» голоса.
        eq.bands[3].filterType = .highShelf
        eq.bands[3].frequency = 8000
        eq.bands[3].gain = -5
        eq.bands[3].bypass = false

        eq.globalGain = 0
    }
}

/// Кэш обработанной музыки: один CAF на исходный файл (по образцу VoiceEnhanceStore).
final class MusicEQStore: @unchecked Sendable {
    private let cacheDir: URL
    private let lock = NSLock()
    private var inFlight: [String: Task<URL, Error>] = [:]

    init(cacheDir: URL) {
        self.cacheDir = cacheDir
    }

    /// Гарантирует готовый обработанный файл (из кэша или новым рендером).
    func ensure(source path: String) async throws -> URL {
        let url = cacheFileURL(source: path)
        if FileManager.default.fileExists(atPath: url.path) { return url }

        let key = url.lastPathComponent
        let task = renderTask(key: key, url: url, path: path)
        defer { clearInFlight(key: key) }
        return try await task.value
    }

    private func renderTask(key: String, url: URL, path: String) -> Task<URL, Error> {
        lock.lock(); defer { lock.unlock() }
        if let existing = inFlight[key] { return existing }
        let task = Task.detached(priority: .userInitiated) {
            let working = url.deletingPathExtension().appendingPathExtension("work.caf")
            defer { try? FileManager.default.removeItem(at: working) }
            try MusicEQ.render(sourcePath: path, to: working, isCancelled: { Task.isCancelled })
            if Task.isCancelled { throw CancellationError() }
            // Готовый файл появляется атомарно — отменённый рендер не оставит битого кэша.
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: working, to: url)
            return url
        }
        inFlight[key] = task
        return task
    }

    private func clearInFlight(key: String) {
        lock.lock(); defer { lock.unlock() }
        inFlight[key] = nil
    }

    private func cacheFileURL(source path: String) -> URL {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? Int) ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(path)|\(size)|\(Int(mtime))|\(MusicEQ.cacheKey)"
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDir.appendingPathComponent("\(hash).caf")
    }
}
