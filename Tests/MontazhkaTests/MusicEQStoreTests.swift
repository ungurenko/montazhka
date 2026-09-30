import AVFoundation
import Foundation
import Testing

@testable import MontazhkaKit

@Suite
struct MusicEQStoreTests {
    @Test("independent music stores publish one complete cache without sharing work files")
    func competingMusicRenders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.mov")
        try await TestVideoFactory.make(segments: [(duration: 2, loud: true)], to: source)
        let cache = root.appendingPathComponent("cache")
        let first = MusicEQStore(cacheDir: cache)
        let second = MusicEQStore(cacheDir: cache)
        async let a = first.ensure(source: source.path)
        async let b = second.ensure(source: source.path)
        let (left, right) = try await (a, b)
        #expect(left == right)
        let audio = try AVAudioFile(forReading: left)
        #expect(Double(audio.length) / audio.processingFormat.sampleRate > 1.9)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path) == [left.lastPathComponent])
    }

    @Test("a reader interrupted after serving audio reports a failure instead of successful EOF")
    func interruptedAudioIsNotSuccessfulEOF() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.mov")
        try await TestVideoFactory.make(segments: [(duration: 3, loud: true)], to: source)
        let asset = AVURLAsset(url: source)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
            ])
        reader.add(output)
        #expect(reader.startReading())
        let feeder = ReaderFeeder(reader: reader, output: output, channels: 2)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        feeder.fill(frameCount: 512, abl: buffer.mutableAudioBufferList)
        #expect(feeder.framesServed > 0)
        reader.cancelReading()
        for _ in 0..<100 where feeder.error == nil {
            feeder.fill(frameCount: 4096, abl: buffer.mutableAudioBufferList)
        }
        #expect(feeder.error != nil)
        #expect(feeder.isExhausted)
    }
}
