@preconcurrency import AVFoundation
import Accelerate
import Foundation

/// Цель мастеринга: громкость площадок (−14 LUFS) и потолок пиков.
/// Ограничитель режет ниже `truePeakCeiling`: AAC поднимает пики до ~1 дБ.
struct LoudnessTarget: Sendable, Equatable {
    var integrated = -14.0
    var truePeakCeiling = -1.0
    var limiterCeiling = -2.3
    var maxGainDB = 20.0
}

/// Выровненный звук склейки: CAF Int16 48 кГц стерео ровно на длину ролика.
struct MasteredAudio: Sendable, Equatable {
    let audioURL: URL
    let before: LoudnessMeasurement
    let after: LoudnessMeasurement
    let gainDB: Double
    /// Ограничитель прижал хотя бы один пик сильнее чем на 0,1 дБ.
    let limited: Bool
}

/// Ограничитель true peak с упреждением: пик ищется в 4× передискретизированном
/// сигнале, усиление общее для всех каналов. Выход задержан на `latencyFrames`:
/// за это время усиление плавно опускается к нужному уровню до прихода пика.
struct TruePeakLimiter {
    /// Задержка выхода в кадрах (упреждение).
    let latencyFrames: Int
    private let channelCount: Int
    private let ceiling: Double
    private let releaseStep: Double
    private var oversamplers: [TruePeakOversampler]
    /// Вход по каналам за последние `latencyFrames` кадров — кольцо задержки.
    private var delayed: [[Float]]
    private var delayedPosition = 0
    /// Модули отсчётов за последние `TruePeakOversampler.delayFrames` шагов.
    private var recentMagnitudes: [Float]
    private var magnitudePosition = 0
    private var previousInterPeak: Float = 0
    private var hold: SlidingMinimum
    private var envelope = 1.0
    private var smoothing: MovingAverage
    private var minimumGain = 1.0

    /// Самое сильное прижатие пика за всё время, дБ (0 — не срабатывал).
    var maxReductionDB: Double { -20 * log10(minimumGain) }

    init(sampleRate: Double, channels: Int, ceilingDB: Double, lookaheadMS: Double = 5, releaseMS: Double = 80) {
        precondition(sampleRate > 0 && channels > 0, "TruePeakLimiter needs a sample rate and channels")
        let detectorDelay = TruePeakOversampler.delayFrames
        latencyFrames = max(detectorDelay + 2, Int((lookaheadMS * sampleRate / 1000).rounded()))
        channelCount = channels
        ceiling = pow(10, ceilingDB / 20)
        releaseStep = 1 - exp(-1 / max(1, releaseMS * sampleRate / 1000))
        oversamplers = Array(repeating: TruePeakOversampler(sampleRate: sampleRate), count: channels)
        delayed = Array(repeating: [Float](repeating: 0, count: latencyFrames), count: channels)
        recentMagnitudes = [Float](repeating: 0, count: detectorDelay)
        // Пик замечается через detectorDelay кадров после входа, поэтому окно
        // удержания и сглаживания короче упреждения: к выходу пика усиление уже внизу.
        let window = latencyFrames - (detectorDelay - 1)
        hold = SlidingMinimum(window: window)
        smoothing = MovingAverage(window: window)
    }

    /// Обрабатывает кусок на месте: на выходе звук, пришедший `latencyFrames` кадров назад.
    mutating func process(_ channels: inout [[Float]]) {
        precondition(channels.count == channelCount, "TruePeakLimiter got a different channel count")
        let count = channels.first?.count ?? 0
        precondition(channels.allSatisfy { $0.count == count }, "TruePeakLimiter channels differ in length")
        guard count > 0 else { return }

        var interPeaks = [Float](repeating: 0, count: count)
        var magnitudes = [Float](repeating: 0, count: count)
        for index in 0..<channelCount {
            let peaks = oversamplers[index].peaks(channels[index])
            interPeaks.withUnsafeMutableBufferPointer { maxima in
                vDSP_vmax(maxima.baseAddress!, 1, peaks, 1, maxima.baseAddress!, 1, vDSP_Length(count))
            }
            magnitudes.withUnsafeMutableBufferPointer { maxima in
                vDSP_vmaxmg(maxima.baseAddress!, 1, channels[index], 1, maxima.baseAddress!, 1, vDSP_Length(count))
            }
        }

        for frame in 0..<count {
            let gain = Float(nextGain(interPeak: interPeaks[frame], magnitude: magnitudes[frame]))
            for index in 0..<channelCount {
                let output = delayed[index][delayedPosition]
                delayed[index][delayedPosition] = channels[index][frame]
                channels[index][frame] = output * gain
            }
            delayedPosition = (delayedPosition + 1) % latencyFrames
        }
    }

    /// Остаток звука, застрявший в задержке: ровно `latencyFrames` кадров.
    mutating func flush() -> [[Float]] {
        var tail = Array(repeating: [Float](repeating: 0, count: latencyFrames), count: channelCount)
        process(&tail)
        return tail
    }

    /// Усиление для кадра, который выходит сейчас. Пик вокруг отсчёта, вошедшего
    /// `delayFrames` шагов назад: сам отсчёт и межотсчётные интервалы по обе стороны.
    private mutating func nextGain(interPeak: Float, magnitude: Float) -> Double {
        let delayedMagnitude = recentMagnitudes[magnitudePosition]
        recentMagnitudes[magnitudePosition] = magnitude
        magnitudePosition = (magnitudePosition + 1) % recentMagnitudes.count
        let detected = Double(max(delayedMagnitude, interPeak, previousInterPeak))
        previousInterPeak = interPeak

        let required = detected > ceiling ? ceiling / detected : 1
        let held = hold.push(required)
        envelope = held < envelope ? held : envelope + (held - envelope) * releaseStep
        let gain = min(1, smoothing.push(envelope))
        minimumGain = min(minimumGain, gain)
        return gain
    }
}

/// Минимум за последние `window` значений (монотонная очередь на кольце).
private struct SlidingMinimum {
    private let window: Int
    private var times: [Int]
    private var values: [Double]
    private var head = 0
    /// Сколько значений сейчас в очереди.
    private var queued = 0
    private var time = 0

    init(window: Int) {
        self.window = window
        times = [Int](repeating: 0, count: window)
        values = [Double](repeating: 0, count: window)
    }

    mutating func push(_ value: Double) -> Double {
        if queued > 0, times[head] <= time - window {
            head = (head + 1) % window
            queued -= 1
        }
        while queued > 0, values[(head + queued - 1) % window] >= value {
            queued -= 1
        }
        let slot = (head + queued) % window
        times[slot] = time
        values[slot] = value
        queued += 1
        time += 1
        return values[head]
    }
}

/// Скользящее среднее за `window` значений; до первых значений считает единицы.
private struct MovingAverage {
    private var values: [Double]
    private var position = 0
    private var sum: Double

    init(window: Int) {
        values = [Double](repeating: 1, count: window)
        sum = Double(window)
    }

    mutating func push(_ value: Double) -> Double {
        sum += value - values[position]
        values[position] = value
        position += 1
        if position == values.count {
            position = 0
            sum = values.reduce(0, +)  // сбрасываем накопленную ошибку округления
        }
        return sum / Double(values.count)
    }
}

/// Мастеринг звука перед экспортом: замер → усиление к цели → ограничитель пиков.
enum LoudnessNormalizer {
    /// Звук склейки всегда сводится в стерео 48 кГц.
    static let sampleRate = 48000.0
    static let channelCount = 2
    /// Промах по громкости, который ещё считается попаданием, LU.
    private static let toleranceLU = 0.5
    /// Прижатие пика сильнее этого считается срабатыванием ограничителя, дБ.
    private static let limitedThresholdDB = 0.1

    /// nil — звук не трогаем: тишина или речи нет.
    static func gainDB(for measurement: LoudnessMeasurement, target: LoudnessTarget) -> Double? {
        guard let integrated = measurement.integratedLUFS else { return nil }
        return min(target.maxGainDB, target.integrated - integrated)
    }

    /// Усиление второго (последнего) прохода, если первый недобрал до цели больше 0,5 LU —
    /// обычно это ограничитель срезал острые пики речи. Добавляем недостачу к усилению
    /// (не выше `maxGainDB`), ограничитель остаётся на том же потолке. nil — поправка
    /// не нужна или усиление уже упёрлось в потолок.
    static func correctiveGainDB(gainDB: Double, after: LoudnessMeasurement, target: LoudnessTarget) -> Double? {
        guard let afterLUFS = after.integratedLUFS else { return nil }
        let shortfall = target.integrated - afterLUFS
        guard shortfall > toleranceLU, gainDB < target.maxGainDB else { return nil }
        return min(target.maxGainDB, gainDB + shortfall)
    }

    /// Проход 1 меряет сведённый звук склейки (`audioMix` применяется), проход 2 пишет
    /// усиленный и ограниченный звук в CAF Int16 48 кГц стерео в `scratchDirectory`.
    /// Чтение — Float32 non-interleaved 48 кГц стерео. Длина результата ровно `duration`.
    /// nil — звука нет или он тихий до нуля. Файл результата удаляет вызывающий.
    @concurrent
    static func master(
        asset: AVAsset, audioMix: AVAudioMix?, duration: Double, target: LoudnessTarget, scratchDirectory: URL,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws -> MasteredAudio? {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let frames = Int((duration * sampleRate).rounded())
        guard !tracks.isEmpty, frames > 0 else { return nil }
        let source = MixSource(asset: asset, tracks: tracks, audioMix: audioMix, frames: frames)
        let cancelled = { isCancelled() || Task.isCancelled }

        var meter = LoudnessMeter(sampleRate: sampleRate, channels: channelCount)
        try source.read(isCancelled: cancelled) { meter.process($0) }
        let before = meter.result()
        guard let gain = gainDB(for: before, target: target) else { return nil }

        try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        var pass = try await render(source, gainDB: gain, target: target, in: scratchDirectory, isCancelled: cancelled)
        if let corrected = correctiveGainDB(gainDB: gain, after: pass.after, target: target) {
            let first = pass.url
            defer { try? FileManager.default.removeItem(at: first) }
            pass = try await render(
                source, gainDB: corrected, target: target, in: scratchDirectory, isCancelled: cancelled)
        }
        return MasteredAudio(
            audioURL: pass.url, before: before, after: pass.after, gainDB: pass.gainDB, limited: pass.limited)
    }

    /// Убирает из склейки все звуковые дорожки и ставит звук файла с нуля.
    /// Меняет саму склейку, а не копию: номера видеодорожек используются дальше.
    static func replaceAudio(in composition: AVMutableComposition, with audioURL: URL) async throws {
        let asset = AVURLAsset(url: audioURL)
        guard let source = try await asset.loadTracks(withMediaType: .audio).first else {
            throw LoudnessError.noAudioTrack
        }
        let range = try await source.load(.timeRange)
        let previous = composition.tracks(withMediaType: .audio)
        guard
            let track = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw LoudnessError.writerFailed }
        do {
            try track.insertTimeRange(range, of: source, at: .zero)
        } catch {
            composition.removeTrack(track)
            throw error
        }
        for old in previous { composition.removeTrack(old) }
    }

    // MARK: - Проход записи

    private struct RenderedPass {
        let url: URL
        let gainDB: Double
        let after: LoudnessMeasurement
        let limited: Bool
    }

    private static func render(
        _ source: MixSource, gainDB: Double, target: LoudnessTarget, in directory: URL, isCancelled: () -> Bool
    ) async throws -> RenderedPass {
        let url = directory.appendingPathComponent("mastered-\(UUID().uuidString).caf")
        do {
            let maxReductionDB = try write(
                source, gainDB: gainDB, ceilingDB: target.limiterCeiling, to: url, isCancelled: isCancelled)
            let after = try await LoudnessMeter.measure(url: url)
            return RenderedPass(
                url: url, gainDB: gainDB, after: after, limited: maxReductionDB > limitedThresholdDB)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Усиливает, ограничивает и пишет CAF Int16; возвращает самое сильное прижатие пика, дБ.
    /// Задержка ограничителя срезается, хвост дописывается из `flush`.
    private static func write(
        _ source: MixSource, gainDB: Double, ceilingDB: Double, to url: URL, isCancelled: () -> Bool
    ) throws -> Double {
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let factor = Float(pow(10, gainDB / 20))
        var limiter = TruePeakLimiter(sampleRate: sampleRate, channels: channelCount, ceilingDB: ceilingDB)
        var latencyLeft = limiter.latencyFrames
        try source.read(isCancelled: isCancelled) { chunk in
            for index in chunk.indices { chunk[index] = vDSP.multiply(factor, chunk[index]) }
            limiter.process(&chunk)
            try append(chunk, skipping: &latencyLeft, to: file)
        }
        try append(limiter.flush(), skipping: &latencyLeft, to: file)
        return limiter.maxReductionDB
    }

    /// Дописывает кусок в файл, пропуская первые `latency` кадров (задержку ограничителя).
    private static func append(_ chunk: [[Float]], skipping latency: inout Int, to file: AVAudioFile) throws {
        let count = chunk.first?.count ?? 0
        let start = min(latency, count)
        latency -= start
        let frames = count - start
        guard frames > 0 else { return }
        guard
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)),
            let data = buffer.floatChannelData
        else { throw LoudnessError.writerFailed }
        buffer.frameLength = AVAudioFrameCount(frames)
        for index in chunk.indices {
            chunk[index].withUnsafeBufferPointer { data[index].update(from: $0.baseAddress! + start, count: frames) }
        }
        try file.write(from: buffer)
    }
}

/// Сведённый звук склейки ровно на `frames` кадров 48 кГц стерео: если чтение
/// кончилось раньше — добиваем тишиной, лишнее отрезаем (длина между проходами
/// с исходниками 44,1 кГц гуляет на ±100 кадров).
private struct MixSource {
    let asset: AVAsset
    let tracks: [AVAssetTrack]
    let audioMix: AVAudioMix?
    let frames: Int

    func read(isCancelled: () -> Bool, consume: (inout [[Float]]) throws -> Void) throws {
        let sampleRate = LoudnessNormalizer.sampleRate
        let channels = LoudnessNormalizer.channelCount
        guard let format = PCMChunk.format(sampleRate: sampleRate, channels: channels) else {
            throw LoudnessError.readerFailed
        }
        let reader = try AVAssetReader(asset: asset)
        // Настройки явные: без них выход следует формату исходника.
        let output = AVAssetReaderAudioMixOutput(
            audioTracks: tracks, audioSettings: PCMChunk.settings(sampleRate: sampleRate, channels: channels))
        output.audioMix = audioMix
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw LoudnessError.readerFailed }
        reader.add(output)
        reader.timeRange = CMTimeRange(
            start: .zero, duration: CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(sampleRate)))
        guard reader.startReading() else { throw LoudnessError.readerFailed }
        defer { reader.cancelReading() }

        var remaining = frames
        while remaining > 0, let sample = output.copyNextSampleBuffer() {
            if isCancelled() { throw CancellationError() }
            var chunk = try PCMChunk.channels(of: sample, format: format)
            let count = min(remaining, chunk.first?.count ?? 0)
            guard count > 0 else { continue }
            if count < chunk[0].count { chunk = chunk.map { Array($0.prefix(count)) } }
            remaining -= count
            try consume(&chunk)
        }
        if reader.status == .failed { throw LoudnessError.readerFailed }
        while remaining > 0 {
            if isCancelled() { throw CancellationError() }
            let count = min(remaining, 4096)
            var silence = Array(repeating: [Float](repeating: 0, count: count), count: channels)
            remaining -= count
            try consume(&silence)
        }
    }
}
