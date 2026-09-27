@preconcurrency import AVFoundation
import Foundation
import Testing

@testable import MontazhkaKit

/// Мастеринг звука перед экспортом: усиление к цели, ограничитель пиков, замена звука в склейке.
@Suite("Loudness normalizer")
struct LoudnessNormalizerTests {
    private struct TestFailure: Error {
        let reason: String
    }

    private func sine(frequency: Double, dbfs: Double, seconds: Double, sampleRate: Double = 48000) -> [Float] {
        let amplitude = pow(10, dbfs / 20)
        let count = Int((seconds * sampleRate).rounded())
        return (0..<count).map { index in
            Float(amplitude * sin(2 * Double.pi * frequency * Double(index) / sampleRate))
        }
    }

    private func measurement(integrated: Double?) -> LoudnessMeasurement {
        LoudnessMeasurement(integratedLUFS: integrated, truePeakDBTP: -10, loudnessRangeLU: nil, seconds: 10)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-master-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Пишет стерео CAF (Float32, 48 кГц) из одинаковых левого и правого каналов.
    private func writeStereo(_ samples: [Float], to url: URL) throws {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let data = buffer.floatChannelData
        else { throw TestFailure(reason: "buffer") }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            data[0].update(from: source.baseAddress!, count: samples.count)
            data[1].update(from: source.baseAddress!, count: samples.count)
        }
        let file = try AVAudioFile(
            forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    /// Прогоняет сигнал через ограничитель; задержка ограничителя уже срезана.
    private func limit(_ channels: [[Float]], ceilingDB: Double, chunk: Int = 1024) -> [[Float]] {
        var limiter = TruePeakLimiter(sampleRate: 48000, channels: channels.count, ceilingDB: ceilingDB)
        var output = [[Float]](repeating: [], count: channels.count)
        let total = channels.first?.count ?? 0
        var start = 0
        while start < total {
            let end = min(total, start + chunk)
            var piece = channels.map { Array($0[start..<end]) }
            limiter.process(&piece)
            for index in piece.indices { output[index] += piece[index] }
            start = end
        }
        let tail = limiter.flush()
        for index in tail.indices { output[index] += tail[index] }
        return output.map { Array($0.dropFirst(limiter.latencyFrames)) }
    }

    @Test("gain reaches the target, is capped at +20 dB and may turn loud audio down")
    func gainForTarget() throws {
        let target = LoudnessTarget()
        #expect(LoudnessNormalizer.gainDB(for: measurement(integrated: -30), target: target) == 16)
        #expect(LoudnessNormalizer.gainDB(for: measurement(integrated: -50), target: target) == 20)
        #expect(LoudnessNormalizer.gainDB(for: measurement(integrated: -8), target: target) == -6)
        #expect(LoudnessNormalizer.gainDB(for: measurement(integrated: nil), target: target) == nil)
    }

    @Test("a second pass runs only when the shortfall is neither the limiter nor the gain cap")
    func correctivePass() {
        let target = LoudnessTarget()
        // Замер разошёлся без вины ограничителя: добираем недостачу.
        let corrected = LoudnessNormalizer.correctiveGainDB(
            gainDB: 10, preLimiter: measurement(integrated: -14.8), after: measurement(integrated: -14.9),
            target: target)
        #expect(abs((corrected ?? 0) - 10.9) < 1e-9)
        // Недостачу съел ограничитель: второй проход только сильнее зажмёт пики.
        #expect(
            LoudnessNormalizer.correctiveGainDB(
                gainDB: 10, preLimiter: measurement(integrated: -14), after: measurement(integrated: -15),
                target: target) == nil)
        // Усиление уже упёрлось в потолок +20 дБ.
        #expect(
            LoudnessNormalizer.correctiveGainDB(
                gainDB: 20, preLimiter: measurement(integrated: -18), after: measurement(integrated: -18),
                target: target) == nil)
        // Недобор в пределах 0,5 LU — цель достигнута.
        #expect(
            LoudnessNormalizer.correctiveGainDB(
                gainDB: 10, preLimiter: measurement(integrated: -14.3), after: measurement(integrated: -14.4),
                target: target) == nil)
    }

    @Test(
        "0 dBFS clicks and a sudden burst come out with a 4×-oversampled peak at the ceiling",
        arguments: [-2.3, -12.0])
    func limiterCatchesClicks(ceilingDB: Double) {
        var signal = sine(frequency: 1000, dbfs: -30, seconds: 3)
        for start in stride(from: 4800, to: signal.count - 8, by: 24000) {
            signal[start] = 1
            // Короткая пачка «+ + − −» даёт межотсчётный пик выше 0 dBFS.
            signal[start + 3] = 1
            signal[start + 4] = 1
            signal[start + 5] = -1
            signal[start + 6] = -1
        }
        // Громкий тон, который начинается сразу с гребня: пик без «разгона».
        for index in 0..<4800 {
            signal[62000 + index] = Float(cos(2 * Double.pi * 1000 * Double(index) / 48000))
        }
        let output = limit([signal, signal], ceilingDB: ceilingDB)
        #expect(output.allSatisfy { $0.count == signal.count })
        var meter = LoudnessMeter(sampleRate: 48000, channels: 2)
        meter.process(output)
        #expect(meter.result().truePeakDBTP <= ceilingDB + 0.1)
    }

    @Test("quiet audio passes the limiter unchanged, only delayed by the lookahead")
    func limiterLeavesQuietAudio() {
        let left = sine(frequency: 440, dbfs: -20, seconds: 1)
        let right = sine(frequency: 3000, dbfs: -26, seconds: 1)
        let output = limit([left, right], ceilingDB: -2.3, chunk: 997)
        #expect(output[0] == left)
        #expect(output[1] == right)
    }

    @Test("master brings a quiet composition to −14 LUFS with exact duration and a true-peak ceiling")
    func masterComposition() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var tone = sine(frequency: 1000, dbfs: -30, seconds: 3)
        tone[72000] = 1  // щелчок: после +16 дБ его должен поймать ограничитель
        let source = directory.appendingPathComponent("tone.caf")
        try writeStereo(tone, to: source)

        let asset = AVURLAsset(url: source)
        let sourceTrack = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let composition = AVMutableComposition()
        let track = try #require(
            composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        try track.insertTimeRange(try await sourceTrack.load(.timeRange), of: sourceTrack, at: .zero)

        let scratch = directory.appendingPathComponent("scratch", isDirectory: true)
        let mastered = try #require(
            try await LoudnessNormalizer.master(
                asset: composition, audioMix: nil, duration: 3, target: LoudnessTarget(),
                scratchDirectory: scratch, isCancelled: { false }))
        let target = LoudnessTarget()
        // Тон даёт −30 LUFS, щелчок добавляет пару десятых.
        #expect(abs(try #require(mastered.before.integratedLUFS) - -30) < 0.3)
        #expect(abs(try #require(mastered.after.integratedLUFS) - target.integrated) < 0.5)
        #expect(mastered.after.truePeakDBTP <= target.limiterCeiling + 0.1)
        #expect(mastered.limited)

        let file = try AVAudioFile(forReading: mastered.audioURL)
        #expect(file.fileFormat.sampleRate == 48000)
        #expect(file.fileFormat.channelCount == 2)
        #expect(abs(Double(file.length) / 48000 - 3) <= 0.001)
    }

    @Test("master returns nil for a composition without audio and for silence")
    func masterSkipsSilence() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let silent = directory.appendingPathComponent("silence.caf")
        try writeStereo([Float](repeating: 0, count: 48000 * 2), to: silent)
        let asset = AVURLAsset(url: silent)
        let sourceTrack = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let composition = AVMutableComposition()
        let track = try #require(
            composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        try track.insertTimeRange(try await sourceTrack.load(.timeRange), of: sourceTrack, at: .zero)
        let scratch = directory.appendingPathComponent("scratch", isDirectory: true)

        let fromSilence = try await LoudnessNormalizer.master(
            asset: composition, audioMix: nil, duration: 2, target: LoudnessTarget(),
            scratchDirectory: scratch, isCancelled: { false })
        #expect(fromSilence == nil)
        let fromNothing = try await LoudnessNormalizer.master(
            asset: AVMutableComposition(), audioMix: nil, duration: 2, target: LoudnessTarget(),
            scratchDirectory: scratch, isCancelled: { false })
        #expect(fromNothing == nil)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []
        #expect(leftovers.isEmpty)
    }

    @Test("replaceAudio leaves exactly one audio track and keeps video track IDs")
    func replaceAudio() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = directory.appendingPathComponent("talk.mov")
        try await TestVideoFactory.make(segments: [(duration: 2, loud: true)], to: movie)
        let music = directory.appendingPathComponent("music.caf")
        try writeStereo(sine(frequency: 500, dbfs: -20, seconds: 1.5), to: music)

        let movieAsset = AVURLAsset(url: movie)
        let movieVideo = try #require(try await movieAsset.loadTracks(withMediaType: .video).first)
        let movieAudio = try #require(try await movieAsset.loadTracks(withMediaType: .audio).first)
        let composition = AVMutableComposition()
        let video = try #require(
            composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        try video.insertTimeRange(try await movieVideo.load(.timeRange), of: movieVideo, at: .zero)
        for _ in 0..<2 {
            let audio = try #require(
                composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
            try audio.insertTimeRange(try await movieAudio.load(.timeRange), of: movieAudio, at: .zero)
        }
        let videoIDs = composition.tracks(withMediaType: .video).map(\.trackID)

        try await LoudnessNormalizer.replaceAudio(in: composition, with: music)

        let audioTracks = composition.tracks(withMediaType: .audio)
        #expect(audioTracks.count == 1)
        #expect(composition.tracks(withMediaType: .video).map(\.trackID) == videoIDs)
        let range = try #require(audioTracks.first?.timeRange)
        #expect(range.start == .zero)
        #expect(abs(range.duration.seconds - 1.5) < 0.001)
    }
}
