import Foundation
import AVFoundation
import AudioToolbox
import Accelerate

enum VoiceEnhanceError: Error, LocalizedError {
    case noAudioTrack
    case readerFailed
    case engineFailed
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .noAudioTrack: return "в файле нет звуковой дорожки"
        case .readerFailed: return "не удалось прочитать звук из файла"
        case .engineFailed: return "не удалось запустить обработку звука"
        case .renderFailed: return "обработка звука прервалась"
        }
    }
}

/// Оффлайн-улучшение голоса: читает звук исходника целиком, прогоняет через
/// эквалайзер + компрессор/гейт (AVAudioEngine в ручном режиме) и пишет CAF.
/// Ручной режим рендера — синхронный: безопасен для CLI-самопроверки (RunLoop не нужен).
enum VoiceEnhancer {
    /// Синхронная работа с диском и движком — звать из Task.detached.
    static func render(sourcePath: String,
                       settings: VoiceEnhanceSettings,
                       to outURL: URL,
                       isCancelled: () -> Bool) throws {
        // 1. Читаем исходный звук: AVAssetReader (AVAudioFile не открывает .mov/.mp4).
        let asset = AVURLAsset(url: URL(fileURLWithPath: sourcePath))
        guard let track = loadAudioTrackSync(asset) else { throw VoiceEnhanceError.noAudioTrack }
        let (sampleRate, sourceChannels) = pcmInfo(of: track, asset: asset)
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

        // 2. Граф: источник → EQ → компрессор/гейт → выход.
        let feeder = ReaderFeeder(reader: reader, output: output, channels: Int(channels))
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, abl in
            feeder.fill(frameCount: frameCount, abl: abl)
            return noErr
        }

        let eq = AVAudioUnitEQ(numberOfBands: 3)
        configureEQ(eq, settings: settings)

        let dyn = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_DynamicsProcessor,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0))
        configureDynamics(dyn, settings: settings)

        let engine = AVAudioEngine()
        engine.attach(source)
        engine.attach(eq)
        engine.attach(dyn)
        engine.connect(source, to: eq, format: format)
        engine.connect(eq, to: dyn, format: format)
        engine.connect(dyn, to: engine.mainMixerNode, format: format)

        do {
            try engine.enableManualRenderingMode(.offline, format: format,
                                                 maximumFrameCount: 4096)
            try engine.start()
        } catch {
            throw VoiceEnhanceError.engineFailed
        }
        defer { engine.stop() }

        // 3. Проход 1: рендер во временный CAF (Float32) + замер RMS и пика.
        let tmpURL = outURL.deletingPathExtension().appendingPathExtension("tmp.caf")
        try? FileManager.default.removeItem(at: tmpURL)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let tmpFile = try AVAudioFile(forWriting: tmpURL, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channels),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true
        ], commonFormat: .pcmFormatFloat32, interleaved: false)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                            frameCapacity: 4096)
        else { throw VoiceEnhanceError.engineFailed }

        var sumSquares = 0.0
        var sampleCount = 0
        var peak: Float = 0
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
                measure(buffer, sumSquares: &sumSquares, count: &sampleCount, peak: &peak)
                try tmpFile.write(from: buffer)
                framesWritten += real
                if feeder.isExhausted && framesWritten >= served { break renderLoop }
            case .insufficientDataFromInputNode:
                continue
            default:
                throw VoiceEnhanceError.renderFailed
            }
        }

        guard framesWritten > 0 else { throw VoiceEnhanceError.noAudioTrack }

        // 4. Проход 2: нормализация громкости → итоговый CAF Int16.
        // Цель ~ −20 dBFS RMS (примерно −16 LUFS для речи), без клиппинга.
        let rms = (sumSquares / Double(max(sampleCount, 1))).squareRoot()
        let rmsDB = 20 * log10(max(rms, 1e-6))
        var gain = Float(pow(10.0, (-20.0 - rmsDB) / 20.0))
        gain = min(gain, 10)                              // не больше +20 дБ
        if peak > 0 { gain = min(gain, 0.98 / peak) }     // пик после усиления ≤ 0.98

        try applyGain(from: tmpURL, to: outURL, gain: gain,
                      sampleRate: sampleRate, channels: channels, isCancelled: isCancelled)
    }

    // MARK: - Параметры эффектов

    private static func configureEQ(_ eq: AVAudioUnitEQ, settings: VoiceEnhanceSettings) {
        let noise = Float(settings.noiseReduction)
        let presence = Float(settings.presence)

        // Срез низкого гула — всегда включён, глубже при сильной чистке шума.
        eq.bands[0].filterType = .highPass
        eq.bands[0].frequency = 60 + 0.6 * noise          // 60–120 Гц
        eq.bands[0].bandwidth = 0.5
        eq.bands[0].bypass = false

        // «Звонкость»: подъём разборчивости речи.
        eq.bands[1].filterType = .parametric
        eq.bands[1].frequency = 3500
        eq.bands[1].bandwidth = 1.0
        eq.bands[1].gain = 6 * presence / 100             // 0…+6 дБ
        eq.bands[1].bypass = false

        // Лёгкий «воздух» сверху.
        eq.bands[2].filterType = .highShelf
        eq.bands[2].frequency = 8000
        eq.bands[2].gain = 3 * presence / 100             // 0…+3 дБ
        eq.bands[2].bypass = false

        eq.globalGain = 0
    }

    private static func configureDynamics(_ dyn: AVAudioUnitEffect, settings: VoiceEnhanceSettings) {
        let leveling = Float(settings.leveling)
        let noise = Float(settings.noiseReduction)
        let unit = dyn.audioUnit

        func set(_ param: AudioUnitParameterID, _ value: Float) {
            AudioUnitSetParameter(unit, param, kAudioUnitScope_Global, 0, value, 0)
        }

        // Компрессор: чем выше «Выравнивание», тем ниже порог и жёстче сжатие.
        set(kDynamicsProcessorParam_Threshold, -10 - 0.2 * leveling)        // −10…−30 дБ
        set(kDynamicsProcessorParam_HeadRoom, 17.5 - 0.125 * leveling)      // 17.5…5
        set(kDynamicsProcessorParam_AttackTime, 0.005)
        set(kDynamicsProcessorParam_ReleaseTime, 0.1)

        // Гейт (экспандер): приглушает то, что тише порога — фоновый шум в паузах.
        set(kDynamicsProcessorParam_ExpansionThreshold, -65 + 0.25 * noise) // −65…−40 дБ
        set(kDynamicsProcessorParam_ExpansionRatio, 1 + 0.09 * noise)       // 1…10

        // Усиление не здесь — его делает нормализация вторым проходом.
        set(kDynamicsProcessorParam_OverallGain, 0)
    }

    // MARK: - Замер и нормализация

    private static func measure(_ buffer: AVAudioPCMBuffer,
                                sumSquares: inout Double, count: inout Int, peak: inout Float) {
        guard let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        for ch in 0..<Int(buffer.format.channelCount) {
            var channelPeak: Float = 0
            vDSP_maxmgv(data[ch], 1, &channelPeak, vDSP_Length(frames))
            peak = max(peak, channelPeak)
            var meanSquare: Float = 0
            vDSP_measqv(data[ch], 1, &meanSquare, vDSP_Length(frames))
            sumSquares += Double(meanSquare) * Double(frames)
            count += frames
        }
    }

    private static func applyGain(from inURL: URL, to outURL: URL, gain: Float,
                                  sampleRate: Double, channels: AVAudioChannelCount,
                                  isCancelled: () -> Bool) throws {
        let inFile = try AVAudioFile(forReading: inURL,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        try? FileManager.default.removeItem(at: outURL)
        let outFile = try AVAudioFile(forWriting: outURL, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channels),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ], commonFormat: .pcmFormatFloat32, interleaved: false)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: inFile.processingFormat,
                                            frameCapacity: 32768)
        else { throw VoiceEnhanceError.renderFailed }

        var factor = gain
        while inFile.framePosition < inFile.length {
            if isCancelled() { throw CancellationError() }
            try inFile.read(into: buffer)
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
            for ch in 0..<Int(buffer.format.channelCount) {
                vDSP_vsmul(data[ch], 1, &factor, data[ch], 1, vDSP_Length(buffer.frameLength))
            }
            try outFile.write(from: buffer)
        }
    }

    // MARK: - Чтение исходника (используется и обработкой музыки — MusicEQ)

    static func loadAudioTrackSync(_ asset: AVURLAsset) -> AVAssetTrack? {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var track: AVAssetTrack?
        asset.loadTracks(withMediaType: .audio) { tracks, _ in
            track = tracks?.first
            semaphore.signal()
        }
        semaphore.wait()
        return track
    }

    /// Узнаёт частоту и число каналов, заглянув в первый кусок данных дорожки.
    static func pcmInfo(of track: AVAssetTrack, asset: AVURLAsset) -> (sampleRate: Double, channels: Int) {
        guard let reader = try? AVAssetReader(asset: asset) else { return (48000, 2) }
        let probe = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(probe) else { return (48000, 2) }
        reader.add(probe)
        guard reader.startReading() else { return (48000, 2) }
        defer { reader.cancelReading() }
        while reader.status == .reading {
            guard let sample = probe.copyNextSampleBuffer() else { break }
            guard let description = CMSampleBufferGetFormatDescription(sample),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
                  asbd.mSampleRate > 0 else { continue }
            return (asbd.mSampleRate, Int(max(1, asbd.mChannelsPerFrame)))
        }
        return (48000, 2)
    }
}

/// Кормит источник движка сэмплами из AVAssetReader.
/// Зовётся синхронно внутри renderOffline — одного потока достаточно, замки не нужны.
final class ReaderFeeder {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let channels: Int
    private var leftover: [Float] = []
    private var leftoverOffset = 0
    private var readerDone = false

    /// Сколько настоящих (не добитых нулями) кадров уже отдано движку.
    private(set) var framesServed: AVAudioFramePosition = 0
    var isExhausted: Bool { readerDone && leftoverOffset >= leftover.count }

    init(reader: AVAssetReader, output: AVAssetReaderTrackOutput, channels: Int) {
        self.reader = reader
        self.output = output
        self.channels = channels
    }

    func fill(frameCount: AVAudioFrameCount, abl: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        let needed = Int(frameCount)
        var produced = 0

        while produced < needed {
            if leftoverOffset >= leftover.count {
                guard refillLeftover() else { break }
            }
            let framesAvailable = (leftover.count - leftoverOffset) / channels
            let frames = min(needed - produced, framesAvailable)
            guard frames > 0 else { break }
            // Расплетаем interleaved-поток по каналам движка.
            for ch in 0..<min(channels, buffers.count) {
                guard let dst = buffers[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                for f in 0..<frames {
                    dst[produced + f] = leftover[leftoverOffset + f * channels + ch]
                }
            }
            leftoverOffset += frames * channels
            produced += frames
        }

        framesServed += AVAudioFramePosition(produced)

        // Добиваем тишиной, если исходник кончился посреди буфера.
        if produced < needed {
            for ch in 0..<buffers.count {
                guard let dst = buffers[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                for f in produced..<needed { dst[f] = 0 }
            }
        }
        for ch in 0..<buffers.count {
            buffers[ch].mDataByteSize = UInt32(needed * MemoryLayout<Float>.size)
        }
    }

    private func refillLeftover() -> Bool {
        guard !readerDone else { return false }
        while reader.status == .reading {
            guard let sample = output.copyNextSampleBuffer() else { break }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let floatCount = length / MemoryLayout<Float>.size
            guard floatCount > 0 else { continue }
            var data = [Float](repeating: 0, count: floatCount)
            let status = data.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                           destination: $0.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { continue }
            leftover = data
            leftoverOffset = 0
            return true
        }
        readerDone = true
        return false
    }
}
