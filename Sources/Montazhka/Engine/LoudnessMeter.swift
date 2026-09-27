@preconcurrency import AVFoundation
import Accelerate
import Foundation

/// Громкость по BS.1770-4 / EBU R128.
struct LoudnessMeasurement: Codable, Equatable, Sendable {
    /// nil — мерить нечего (тишина).
    let integratedLUFS: Double?
    let truePeakDBTP: Double
    let loudnessRangeLU: Double?
    let seconds: Double
}

enum LoudnessError: Error, LocalizedError {
    case noAudioTrack
    case readerFailed
    case writerFailed

    var errorDescription: String? {
        switch self {
        case .noAudioTrack: return "в файле нет звуковой дорожки"
        case .readerFailed: return "не удалось прочитать звук для замера громкости"
        case .writerFailed: return "не удалось записать выровненный по громкости звук"
        }
    }
}

/// Измеритель громкости BS.1770-4 / EBU R128: K-фильтр, блоки 400 мс с шагом 100 мс,
/// абсолютная (−70 LUFS) и относительная (−10 LU) отсечки, LRA по EBU Tech 3342
/// и true peak с передискретизацией. Звук подаётся кусками любой длины: состояние
/// фильтров и незаконченных блоков переходит между вызовами `process`.
struct LoudnessMeter {
    /// Самый тихий пик, который попадает в JSON: −∞ в Codable не кодируется.
    static let peakFloorDB = -144.0

    private let sampleRate: Double
    private let channelCount: Int
    private let weights: [Double]
    private let filter: BiquadCascade
    /// Задержки K-фильтра по каналам — его состояние между кусками.
    private var delays: [[Double]]
    private var oversamplers: [TruePeakOversampler]
    /// Отсчётов в 100-мс отрезке: из 4 отрезков складывается блок, из 30 — окно LRA.
    private let segmentLength: Int
    private var segmentBuffers: [[Double]]
    /// Взвешенная энергия последних (не больше 30) закрытых отрезков.
    private var recentSegments: [Double] = []
    private var closedSegments = 0
    private var blockPowers: [Double] = []
    private var shortTermPowers: [Double] = []
    private var peak: Float = 0
    private var frames = 0

    init(sampleRate: Double, channels: Int) {
        precondition(sampleRate > 0 && channels > 0, "LoudnessMeter needs a sample rate and channels")
        self.sampleRate = sampleRate
        channelCount = channels
        weights = (0..<channels).map { Self.channelWeight($0, of: channels) }
        filter = BiquadCascade(coefficients: Self.kWeightingCoefficients(sampleRate: sampleRate))
        let delay = [Double](repeating: 0, count: BiquadCascade.delayLength(sections: 2))
        delays = Array(repeating: delay, count: channels)
        oversamplers = Array(repeating: TruePeakOversampler(sampleRate: sampleRate), count: channels)
        segmentLength = max(1, Int((sampleRate / 10).rounded()))
        segmentBuffers = Array(repeating: [], count: channels)
    }

    /// Один кусок звука: по массиву на канал, у всех каналов одна длина.
    mutating func process(_ channels: [[Float]]) {
        precondition(channels.count == channelCount, "LoudnessMeter got a different channel count")
        let count = channels.first?.count ?? 0
        precondition(channels.allSatisfy { $0.count == count }, "LoudnessMeter channels differ in length")
        guard count > 0 else { return }
        frames += count

        var filtered: [[Double]] = []
        for index in 0..<channelCount {
            peak = max(peak, vDSP.maximum(oversamplers[index].peaks(channels[index])))
            filtered.append(kWeighted(channels[index], channel: index))
        }

        var offset = 0
        while offset < count {
            let take = min(segmentLength - segmentBuffers[0].count, count - offset)
            for index in 0..<channelCount {
                segmentBuffers[index].append(contentsOf: filtered[index][offset..<(offset + take)])
            }
            offset += take
            if segmentBuffers[0].count == segmentLength { closeSegment() }
        }
    }

    func result() -> LoudnessMeasurement {
        let peakDB = peak > 0 ? max(Self.peakFloorDB, 20 * log10(Double(peak))) : Self.peakFloorDB
        return LoudnessMeasurement(
            integratedLUFS: Self.integratedLoudness(blockPowers),
            truePeakDBTP: peakDB,
            loudnessRangeLU: Self.loudnessRange(shortTermPowers),
            seconds: Double(frames) / sampleRate)
    }

    /// Замер первой звуковой дорожки файла (MP4/MOV/CAF) на её собственной частоте.
    /// Каналов не больше двух: моно остаётся моно, иначе Core Audio сводит в стерео.
    /// `progress` — доля прочитанной дорожки 0…1.
    @concurrent
    static func measure(url: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws -> LoudnessMeasurement {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw LoudnessError.noAudioTrack
        }
        let descriptions = try await track.load(.formatDescriptions)
        let stream = descriptions.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let sourceRate = stream?.mSampleRate ?? 0
        let sampleRate = sourceRate > 0 ? sourceRate : 48000
        let channels = min(2, max(1, Int(stream?.mChannelsPerFrame ?? 2)))
        let length = progress == nil ? 0 : (try? await track.load(.timeRange).end.seconds) ?? 0
        guard let format = PCMChunk.format(sampleRate: sampleRate, channels: channels) else {
            throw LoudnessError.readerFailed
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track, outputSettings: PCMChunk.settings(sampleRate: sampleRate, channels: channels))
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw LoudnessError.readerFailed }
        reader.add(output)
        guard reader.startReading() else { throw LoudnessError.readerFailed }
        defer { reader.cancelReading() }

        var meter = LoudnessMeter(sampleRate: sampleRate, channels: channels)
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            meter.process(try PCMChunk.channels(of: sample, format: format))
            if let progress, length > 0 {
                let end = CMSampleBufferGetPresentationTimeStamp(sample) + CMSampleBufferGetDuration(sample)
                progress(min(1, end.seconds / length))
            }
        }
        if reader.status == .failed { throw LoudnessError.readerFailed }
        return meter.result()
    }

    // MARK: - K-фильтр

    /// Коэффициенты двух звеньев K-фильтра [b0, b1, b2, a1, a2] × 2 для любой частоты:
    /// из аналоговых прототипов, как в libebur128 (полка +4 дБ, затем срез низа).
    static func kWeightingCoefficients(sampleRate: Double) -> [Double] {
        let shelfK = tan(Double.pi * 1681.974450955533 / sampleRate)
        let shelfQ = 0.7071752369554196
        let vh = pow(10, 3.999843853973347 / 20)
        let vb = pow(vh, 0.4996667741545416)
        let shelfA0 = 1 + shelfK / shelfQ + shelfK * shelfK
        let shelf = [
            (vh + vb * shelfK / shelfQ + shelfK * shelfK) / shelfA0,
            2 * (shelfK * shelfK - vh) / shelfA0,
            (vh - vb * shelfK / shelfQ + shelfK * shelfK) / shelfA0,
            2 * (shelfK * shelfK - 1) / shelfA0,
            (1 - shelfK / shelfQ + shelfK * shelfK) / shelfA0,
        ]

        let passK = tan(Double.pi * 38.13547087602444 / sampleRate)
        let passQ = 0.5003270373238773
        let passA0 = 1 + passK / passQ + passK * passK
        let highPass = [
            1, -2, 1,
            2 * (passK * passK - 1) / passA0,
            (1 - passK / passQ + passK * passK) / passA0,
        ]
        return shelf + highPass
    }

    private mutating func kWeighted(_ samples: [Float], channel: Int) -> [Double] {
        let count = samples.count
        var input = [Double](repeating: 0, count: count)
        vDSP_vspdp(samples, 1, &input, 1, vDSP_Length(count))
        var output = [Double](repeating: 0, count: count)
        let setup = filter.setup
        delays[channel].withUnsafeMutableBufferPointer { delay in
            vDSP_biquadD(setup, delay.baseAddress!, input, 1, &output, 1, vDSP_Length(count))
        }
        return output
    }

    /// Вес канала: для 5.1 (L R C LFE Ls Rs) LFE не считается, тылы ×1.41; иначе 1.
    private static func channelWeight(_ index: Int, of channels: Int) -> Double {
        guard channels == 6 else { return 1 }
        return [1, 1, 1, 0, 1.41, 1.41][index]
    }

    // MARK: - Блоки и отсечки

    private mutating func closeSegment() {
        var energy = 0.0
        for index in 0..<channelCount {
            var sum = 0.0
            vDSP_svesqD(segmentBuffers[index], 1, &sum, vDSP_Length(segmentLength))
            energy += weights[index] * sum
            segmentBuffers[index].removeAll(keepingCapacity: true)
        }
        recentSegments.append(energy)
        if recentSegments.count > 30 { recentSegments.removeFirst() }
        closedSegments += 1

        // Блок 400 мс = 4 отрезка; окно LRA 3 с = 30 отрезков с шагом 1 с.
        if closedSegments >= 4 {
            blockPowers.append(recentSegments.suffix(4).reduce(0, +) / Double(4 * segmentLength))
        }
        if closedSegments >= 30, (closedSegments - 30) % 10 == 0 {
            shortTermPowers.append(recentSegments.reduce(0, +) / Double(30 * segmentLength))
        }
    }

    private static func loudness(_ power: Double) -> Double {
        -0.691 + 10 * log10(power)
    }

    private static func mean(_ values: [Double]) -> Double {
        values.reduce(0, +) / Double(values.count)
    }

    private static func integratedLoudness(_ powers: [Double]) -> Double? {
        let audible = powers.filter { loudness($0) > -70 }
        guard !audible.isEmpty else { return nil }
        let relativeGate = loudness(mean(audible)) - 10
        let gated = audible.filter { loudness($0) > relativeGate }
        guard !gated.isEmpty else { return nil }
        return loudness(mean(gated))
    }

    /// LRA по EBU Tech 3342: разброс P10…P95 кратковременной громкости после отсечек −70 LUFS и −20 LU.
    private static func loudnessRange(_ powers: [Double]) -> Double? {
        let audible = powers.filter { loudness($0) > -70 }
        guard !audible.isEmpty else { return nil }
        let relativeGate = loudness(mean(audible)) - 20
        let values = audible.map(loudness).filter { $0 > relativeGate }.sorted()
        guard values.count >= 2 else { return nil }
        let last = Double(values.count - 1)
        return values[Int(last * 0.95 + 0.5)] - values[Int(last * 0.10 + 0.5)]
    }
}

/// Каскад биквадов vDSP. Коэффициенты неизменны и общие для всех каналов,
/// состояние (задержки) хранит тот, кто фильтрует.
private final class BiquadCascade {
    let setup: vDSP_biquad_SetupD

    init(coefficients: [Double]) {
        guard let created = vDSP_biquad_CreateSetupD(coefficients, vDSP_Length(coefficients.count / 5)) else {
            preconditionFailure("vDSP could not create the K-weighting filter")
        }
        setup = created
    }

    deinit { vDSP_biquad_DestroySetupD(setup) }

    static func delayLength(sections: Int) -> Int { 2 * sections + 2 }
}

/// Межотсчётные пики по BS.1770-4, приложение 2: 4× полифазный FIR (48 отводов,
/// 4 фазы по 12); от 96 кГц — 2× (фазы 0 и 2 того же фильтра). Выход фазы
/// на отсчёте k — значение сигнала в интервале (k − 6, k − 5): задержка фильтра ~5,9 отсчёта.
struct TruePeakOversampler {
    /// Задержка в отсчётах между входом и интервалом, который описывают выходы фаз.
    static let delayFrames = 6

    private static let taps = 12
    private static let phases: [[Float]] = [
        [
            0.0017089843750, 0.0109863281250, -0.0196533203125, 0.0332031250000, -0.0594482421875, 0.1373291015625,
            0.9721679687500, -0.1022949218750, 0.0476074218750, -0.0266113281250, 0.0148925781250, -0.0083007812500,
        ],
        [
            -0.0291748046875, 0.0292968750000, -0.0517578125000, 0.0891113281250, -0.1665039062500, 0.4650878906250,
            0.7797851562500, -0.2003173828125, 0.1015625000000, -0.0582275390625, 0.0330810546875, -0.0189208984375,
        ],
        [
            -0.0189208984375, 0.0330810546875, -0.0582275390625, 0.1015625000000, -0.2003173828125, 0.7797851562500,
            0.4650878906250, -0.1665039062500, 0.0891113281250, -0.0517578125000, 0.0292968750000, -0.0291748046875,
        ],
        [
            -0.0083007812500, 0.0148925781250, -0.0266113281250, 0.0476074218750, -0.1022949218750, 0.9721679687500,
            0.1373291015625, -0.0594482421875, 0.0332031250000, -0.0196533203125, 0.0109863281250, 0.0017089843750,
        ],
    ]

    private let activePhases: [[Float]]
    private var history = [Float](repeating: 0, count: Self.taps - 1)

    init(sampleRate: Double) {
        activePhases = sampleRate >= 96000 ? [Self.phases[0], Self.phases[2]] : Self.phases
    }

    /// Для каждого входного отсчёта — наибольший модуль среди фаз на этом шаге.
    /// Свёртка — развёрнутый цикл, а не vDSP_conv: у того последний бит зависит от места
    /// отсчёта в куске, и пик менялся бы от нарезки звука. Компилятор векторизует цикл сам,
    /// а развёртка держит терпимой скорость отладочной сборки тестов.
    mutating func peaks(_ samples: [Float]) -> [Float] {
        let count = samples.count
        var result = [Float](repeating: 0, count: count)
        guard count > 0 else { return result }
        let extended = history + samples
        extended.withUnsafeBufferPointer { input in
            result.withUnsafeMutableBufferPointer { maxima in
                for phase in activePhases {
                    Self.convolve(phase, input: input.baseAddress!, count: count, maxima: maxima.baseAddress!)
                }
            }
        }
        history = Array(extended.suffix(Self.taps - 1))
        return result
    }

    /// Выход фазы на отсчёте k опирается на отсчёты k−11…k (во входе это x[k]…x[k+11]);
    /// в `maxima[k]` остаётся наибольший модуль.
    private static func convolve(
        _ phase: [Float], input: UnsafePointer<Float>, count: Int, maxima: UnsafeMutablePointer<Float>
    ) {
        let c0 = phase[0]
        let c1 = phase[1]
        let c2 = phase[2]
        let c3 = phase[3]
        let c4 = phase[4]
        let c5 = phase[5]
        let c6 = phase[6]
        let c7 = phase[7]
        let c8 = phase[8]
        let c9 = phase[9]
        let c10 = phase[10]
        let c11 = phase[11]
        for frame in 0..<count {
            let x = input + frame
            var sum = c0 * x[11]
            sum += c1 * x[10]
            sum += c2 * x[9]
            sum += c3 * x[8]
            sum += c4 * x[7]
            sum += c5 * x[6]
            sum += c6 * x[5]
            sum += c7 * x[4]
            sum += c8 * x[3]
            sum += c9 * x[2]
            sum += c10 * x[1]
            sum += c11 * x[0]
            maxima[frame] = max(maxima[frame], abs(sum))
        }
    }
}

/// Кусок несжатого звука из AVAssetReader: Float32, каналы раздельно (non-interleaved).
enum PCMChunk {
    static func settings(sampleRate: Double, channels: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
            AVLinearPCMIsBigEndianKey: false,
        ]
    }

    static func format(sampleRate: Double, channels: Int) -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels), interleaved: false)
    }

    /// Отсчёты буфера по каналам; буфер должен быть в формате `settings`.
    static func channels(of sample: CMSampleBuffer, format: AVAudioFormat) throws -> [[Float]] {
        let channelCount = Int(format.channelCount)
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0 else { return Array(repeating: [], count: channelCount) }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            throw LoudnessError.readerFailed
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        guard status == noErr, let data = buffer.floatChannelData else { throw LoudnessError.readerFailed }
        return (0..<channelCount).map { Array(UnsafeBufferPointer(start: data[$0], count: frames)) }
    }
}
