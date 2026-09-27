@preconcurrency import AVFoundation
import Foundation
import Testing

@testable import MontazhkaKit

@Suite("Seam probe around cuts")
struct SeamProbeTests {
    private let rate = 48_000.0
    private let cut = 1.5

    /// Синус длиной `seconds`; `phase` сдвигает фазу (радианы).
    private func sine(
        _ seconds: Double, amplitude: Double = 0.5, frequency: Double = 440, phase: Double = 0, from start: Double = 0
    ) -> [Float] {
        (0..<Int((seconds * rate).rounded())).map { index in
            let time = start + Double(index) / rate
            return Float(amplitude * sin(2 * .pi * frequency * time + phase))
        }
    }

    /// Предсказуемый «шум» без генератора случайных чисел системы.
    private func noise(_ count: Int, seed: UInt64 = 42) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Double(state >> 33) / Double(1 << 31)) - 0.5
        }
    }

    private func index(_ seconds: Double) -> Int { Int((seconds * rate).rounded()) }

    // MARK: - Audio

    @Test("a step discontinuity in a sine at the cut is a click")
    func stepIsClick() {
        let samples = sine(cut) + sine(cut, phase: .pi / 2, from: cut)
        let finding = SeamProbe.audio(samples: samples, sampleRate: rate, cutOffset: cut)
        #expect(finding.click)
        #expect(finding.clickRatio >= SeamProbe.clickRatioThreshold)
    }

    @Test("a smooth sine through the cut is not a click")
    func smoothSineNoClick() {
        let finding = SeamProbe.audio(samples: sine(2 * cut), sampleRate: rate, cutOffset: cut)
        #expect(!finding.click)
        #expect(finding.clickRatio < 1.5)
        #expect(finding.dropoutMS == 0)
        #expect(abs(finding.levelJumpDB) < 0.1)
    }

    @Test("digital silence around the cut gives a finite ratio and no click")
    func silenceIsFinite() {
        let finding = SeamProbe.audio(samples: [Float](repeating: 0, count: index(3)), sampleRate: rate, cutOffset: cut)
        #expect(finding.clickRatio == 0)
        #expect(!finding.click)
        #expect(finding.dropoutMS == 0)
    }

    @Test("a 40 ms hole in a tone is a dropout of about 40 ms")
    func holeIsDropout() {
        var aligned = sine(2 * cut)
        aligned.replaceSubrange(index(cut)..<index(cut + 0.040), with: repeatElement(0, count: index(0.040)))
        #expect(abs(SeamProbe.audio(samples: aligned, sampleRate: rate, cutOffset: cut).dropoutMS - 40) <= 5)

        var offGrid = sine(2 * cut)
        let holeStart = index(cut - 0.0123)
        offGrid.replaceSubrange(holeStart..<(holeStart + index(0.040)), with: repeatElement(0, count: index(0.040)))
        #expect(abs(SeamProbe.audio(samples: offGrid, sampleRate: rate, cutOffset: cut).dropoutMS - 40) <= 5)
    }

    @Test("a long pause around the cut (quiet beyond ±250 ms) is not a dropout")
    func pauseIsNotDropout() {
        var samples = sine(2 * cut)
        samples.replaceSubrange(index(cut - 0.3)..<index(cut + 0.3), with: repeatElement(0, count: index(0.6)))
        #expect(SeamProbe.audio(samples: samples, sampleRate: rate, cutOffset: cut).dropoutMS == 0)
    }

    @Test("music-like continuous noise across the cut is neither a dropout nor a click")
    func musicIsNotDropout() {
        let raw = noise(index(2 * cut))
        let samples = raw.enumerated().map { offset, value in
            // Громкость «дышит» два раза в секунду, как музыка, но не проваливается в тишину.
            let time = Double(offset) / rate
            return value * Float(0.3 + 0.3 * abs(sin(2 * .pi * 2 * time)))
        }
        let finding = SeamProbe.audio(samples: samples, sampleRate: rate, cutOffset: cut)
        #expect(finding.dropoutMS == 0)
        #expect(!finding.click)
    }

    @Test("level jump is before minus after, in dB")
    func levelJump() {
        let louderBefore = sine(cut, amplitude: 0.5) + sine(cut, amplitude: 0.25, from: cut)
        #expect(
            abs(SeamProbe.audio(samples: louderBefore, sampleRate: rate, cutOffset: cut).levelJumpDB - 6.02) < 0.1)

        let louderAfter = sine(cut, amplitude: 0.25) + sine(cut, amplitude: 0.5, from: cut)
        #expect(abs(SeamProbe.audio(samples: louderAfter, sampleRate: rate, cutOffset: cut).levelJumpDB + 6.02) < 0.1)
    }

    // MARK: - Words

    private func words(_ items: [(String, Double, Double)]) -> [SeamWord] {
        items.map { SeamWord(text: $0.0, start: $0.1, end: $0.2) }
    }

    @Test("a word missing right at the cut is suspect")
    func missingAtCutIsSuspect() {
        let expected = words([
            ("Сегодня", 0.2, 0.5), ("мы", 0.55, 0.65), ("поговорим", 0.7, 0.95), ("о", 1.05, 1.1),
            ("монтаже.", 1.15, 1.6),
        ])
        let heard = words([("сегодня", 0.2, 0.5), ("мы", 0.55, 0.65), ("о", 1.05, 1.1), ("монтаже", 1.15, 1.6)])
        let finding = SeamProbe.words(expected: expected, heard: heard, cut: 1.0)
        #expect(finding.missing == ["поговорим"])
        #expect(finding.suspect)
        #expect(finding.expected == ["сегодня", "мы", "поговорим", "о", "монтаже"])
        #expect(finding.heard == ["сегодня", "мы", "о", "монтаже"])
    }

    @Test("a different ending of the same word is not missing")
    func differentEndingNotMissing() {
        let expected = words([("Давайте", 0.1, 0.5), ("сделаем", 0.6, 0.95), ("нарезку", 1.05, 1.5)])
        let heard = words([("давайте", 0.1, 0.5), ("сделаю", 0.6, 0.95), ("нарезку", 1.05, 1.5)])
        let finding = SeamProbe.words(expected: expected, heard: heard, cut: 1.0)
        #expect(finding.missing.isEmpty)
        #expect(!finding.suspect)
    }

    @Test("a word missing far from the cut is reported but not suspect; one across the cut is suspect")
    func missingFarFromCut() {
        let expected = words([("Привет", 0.0, 0.3), ("всем", 0.4, 0.6), ("кто", 1.3, 1.4), ("смотрит", 1.5, 1.9)])
        let farFinding = SeamProbe.words(
            expected: expected, heard: words([("привет", 0.0, 0.3), ("кто", 1.3, 1.4), ("смотрит", 1.5, 1.9)]),
            cut: 1.0)
        #expect(farFinding.missing == ["всем"])
        #expect(!farFinding.suspect)

        let across = words([("один", 0.2, 0.5), ("двадцать", 0.9, 1.2), ("три", 1.3, 1.5)])
        let acrossFinding = SeamProbe.words(
            expected: across, heard: words([("один", 0.2, 0.5), ("три", 1.3, 1.5)]), cut: 1.0)
        #expect(acrossFinding.missing == ["двадцать"])
        #expect(acrossFinding.suspect)
    }

    // MARK: - Picture

    @Test("black frame threshold")
    func blackThreshold() {
        #expect(SeamProbe.isBlack(meanLuma: 0))
        #expect(SeamProbe.isBlack(meanLuma: 0.029))
        #expect(!SeamProbe.isBlack(meanLuma: 0.03))
        #expect(!SeamProbe.isBlack(meanLuma: 0.2))
    }

    @Test("mean luma of real frames: black video is black, grey video is about 0.5")
    func meanLumaOfFrames() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("seam-luma-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let black = directory.appendingPathComponent("black.mov")
        let grey = directory.appendingPathComponent("grey.mov")
        try await TestVideoFactory.make(segments: [(duration: 2, loud: false)], videoLuma: 0, to: black)
        try await TestVideoFactory.make(segments: [(duration: 2, loud: false)], videoLuma: 128, to: grey)

        let blackLuma = try await SeamProbe.meanLuma(asset: AVURLAsset(url: black), times: [0.5, 1.5])
        let greyLuma = try await SeamProbe.meanLuma(asset: AVURLAsset(url: grey), times: [0.5, 1.5])
        #expect(blackLuma.count == 2)
        #expect(blackLuma.allSatisfy { SeamProbe.isBlack(meanLuma: $0) })
        #expect(greyLuma.count == 2)
        #expect(greyLuma.allSatisfy { abs($0 - 0.5) < 0.05 })
    }

    // MARK: - Reading audio

    /// AAC-файл 44.1 кГц: тишина и один щелчок в `clickAt` секунд.
    private func writeAACClick(to url: URL, seconds: Double, clickAt: Double) throws {
        let fileRate = 44_100.0
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: fileRate, AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000,
            ])
        let frames = AVAudioFrameCount(seconds * fileRate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        buffer.frameLength = frames
        let channel = try #require(buffer.floatChannelData?[0])
        for frame in 0..<Int(frames) { channel[frame] = 0 }
        channel[Int((clickAt * fileRate).rounded())] = 0.9
        try file.write(from: buffer)
    }

    @Test("samples(url:) returns the requested span aligned to the file timeline")
    func readsAlignedSamples() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("seam-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("click.m4a")
        try writeAACClick(to: url, seconds: 3, clickAt: 1.25)

        let read = try await SeamProbe.samples(url: url, from: 1.0, to: 2.0)
        #expect(read.sampleRate == 48_000)
        #expect(abs(read.samples.count - 48_000) <= 1024)
        let peak = try #require(read.samples.indices.max { abs(read.samples[$0]) < abs(read.samples[$1]) })
        #expect(abs(Double(peak) / read.sampleRate - 0.25) <= 0.001)
    }
}
