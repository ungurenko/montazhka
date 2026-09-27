@preconcurrency import AVFoundation
import Foundation
import Testing

@testable import MontazhkaKit

/// Эталонные сигналы BS.1770-4 / EBU R128: громкость, отсечки, true peak и LRA.
/// «−20 dBFS» у синуса — амплитуда 10^(−20/20) от полной шкалы.
@Suite("Loudness meter")
struct LoudnessMeterTests {
    private func sine(
        frequency: Double, dbfs: Double, seconds: Double, sampleRate: Double = 48000, phase: Double = 0
    ) -> [Float] {
        let amplitude = pow(10, dbfs / 20)
        let count = Int((seconds * sampleRate).rounded())
        return (0..<count).map { index in
            Float(amplitude * sin(2 * Double.pi * frequency * Double(index) / sampleRate + phase))
        }
    }

    private func measure(_ channels: [[Float]], sampleRate: Double = 48000, chunk: Int? = nil) -> LoudnessMeasurement {
        var meter = LoudnessMeter(sampleRate: sampleRate, channels: channels.count)
        let total = channels.first?.count ?? 0
        let step = chunk ?? max(total, 1)
        var start = 0
        while start < total {
            let end = min(total, start + step)
            meter.process(channels.map { Array($0[start..<end]) })
            start = end
        }
        return meter.result()
    }

    private func integrated(_ measurement: LoudnessMeasurement) throws -> Double {
        try #require(measurement.integratedLUFS)
    }

    @Test("48 kHz K-weighting matches the coefficients printed in BS.1770-4")
    func kWeightingAt48k() {
        let derived = LoudnessMeter.kWeightingCoefficients(sampleRate: 48000)
        let printed = [
            1.53512485958697, -2.69169618940638, 1.19839281085285, -1.69065929318241, 0.73248077421585,
            1.0, -2.0, 1.0, -1.99004745483398, 0.99007225036621,
        ]
        #expect(derived.count == printed.count)
        for (value, reference) in zip(derived, printed) {
            #expect(abs(value - reference) < 1e-8)
        }
    }

    @Test("997 Hz at 0 dBFS in the left channel only reads −3.01 LUFS")
    func leftChannelOnly() throws {
        let left = sine(frequency: 997, dbfs: 0, seconds: 20)
        let result = measure([left, [Float](repeating: 0, count: left.count)])
        #expect(abs(try integrated(result) - -3.01) < 0.1)
    }

    @Test("identical −23 dBFS tone in both channels reads −23 LUFS: channel powers add")
    func stereoTone() throws {
        let tone = sine(frequency: 1000, dbfs: -23, seconds: 20)
        let result = measure([tone, tone])
        #expect(abs(try integrated(result) - -23.0) < 0.1)
        #expect(abs(result.seconds - 20) < 1e-9)
    }

    @Test("mono −20 dBFS tone reads −23 LUFS")
    func monoTone() throws {
        let result = measure([sine(frequency: 1000, dbfs: -20, seconds: 20)])
        #expect(abs(try integrated(result) - -23.0) < 0.1)
    }

    @Test("44.1 kHz reads the same as 48 kHz: filters are derived for the rate")
    func sampleRateIndependent() throws {
        let at48 = sine(frequency: 1000, dbfs: -23, seconds: 20, sampleRate: 48000)
        let at44 = sine(frequency: 1000, dbfs: -23, seconds: 20, sampleRate: 44100)
        let reference = try integrated(measure([at48, at48], sampleRate: 48000))
        let other = measure([at44, at44], sampleRate: 44100)
        #expect(abs(try integrated(other) - reference) < 0.1)
        #expect(abs(other.seconds - 20) < 1e-9)
    }

    @Test("digital silence has no integrated loudness and a finite peak floor")
    func silence() throws {
        let zeros = [Float](repeating: 0, count: 48000 * 5)
        let result = measure([zeros, zeros])
        #expect(result.integratedLUFS == nil)
        #expect(result.loudnessRangeLU == nil)
        #expect(result.truePeakDBTP == -144)
        let json = try JSONEncoder().encode(result)
        #expect(try JSONDecoder().decode(LoudnessMeasurement.self, from: json) == result)
    }

    @Test("trailing silence is gated out of the integrated loudness")
    func gatingIgnoresSilence() throws {
        let tone = sine(frequency: 1000, dbfs: -20, seconds: 10)
        let padded = tone + [Float](repeating: 0, count: 48000 * 10)
        let alone = try integrated(measure([tone, tone]))
        let withSilence = try integrated(measure([padded, padded]))
        #expect(abs(withSilence - alone) < 0.1)
    }

    @Test("a fs/4 sine sampled 45° off its crest reads 0 dBTP, not the −3 dB sample peak")
    func truePeakBetweenSamples() {
        let tone = sine(frequency: 12000, dbfs: 0, seconds: 2, phase: Double.pi / 4)
        let samplePeak = tone.map { abs($0) }.max() ?? 0
        #expect(abs(20 * log10(Double(samplePeak)) - -3.01) < 0.05)
        let result = measure([tone, tone])
        #expect(abs(result.truePeakDBTP) < 0.2)
    }

    @Test("20 s at −20 dBFS then 20 s at −30 dBFS spans a 10 LU loudness range")
    func loudnessRange() throws {
        let loud = sine(frequency: 1000, dbfs: -20, seconds: 20)
        let quiet = sine(frequency: 1000, dbfs: -30, seconds: 20)
        let signal = loud + quiet
        let range = try #require(measure([signal, signal]).loudnessRangeLU)
        #expect(abs(range - 10) < 1)
    }

    @Test("chunk size does not change any result")
    func chunkingIsTransparent() {
        let loud = sine(frequency: 997, dbfs: -12, seconds: 8)
        let quiet = sine(frequency: 3000, dbfs: -35, seconds: 6, phase: 1)
        let left = loud + quiet
        let right = quiet + loud
        let whole = measure([left, right])
        let chunked = measure([left, right], chunk: 997)
        #expect(whole == chunked)
    }

    @Test("a mono file is measured as mono at its own sample rate")
    func measuresMonoFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-loudness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tone.caf")
        let tone = sine(frequency: 1000, dbfs: -20, seconds: 5, sampleRate: 44100)
        let format = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(tone.count)))
        buffer.frameLength = AVAudioFrameCount(tone.count)
        let data = try #require(buffer.floatChannelData)
        tone.withUnsafeBufferPointer { data[0].update(from: $0.baseAddress!, count: tone.count) }
        do {
            let file = try AVAudioFile(
                forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        let result = try await LoudnessMeter.measure(url: url)
        #expect(abs(try integrated(result) - -23.0) < 0.1)
        #expect(abs(result.seconds - 5) < 0.01)
    }
}
