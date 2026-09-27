import AVFoundation
import Testing

@testable import MontazhkaKit

@Suite
struct MediaPipelineTests {
    @Test
    func testManyFragmentsOfOneVideoLoadOneSourceAndBuildWholeTimeline() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-many-fragments-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await TestVideoFactory.make(segments: [(duration: 12, loud: true)], to: url)

        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let videoTrack = try #require(videoTracks.first)
        let mediaDuration = try await videoTrack.load(.timeRange).duration.seconds
        let source = MediaReference(url: url)
        let fragmentDuration = mediaDuration / 185.0
        let clips = (0..<185).map { index in
            let start = Double(index) * fragmentDuration
            let end = index == 184 ? mediaDuration : Double(index + 1) * fragmentDuration
            return Clip(source: source, start: start, end: end)
        }

        let plan = MediaSourceLoadPlan(clips: clips, enhancedAudio: [:])
        #expect((plan.sources.count) == (1))

        let result = await CompositionBuilder.buildResult(clips: clips)
        #expect(abs((result.composition.duration.seconds) - (mediaDuration)) <= (0.05))
        #expect(result.warnings.isEmpty, "\(result.warnings.map(\.message))")
    }

    @Test("a cut through a steady tone does not click once the audio mix is applied")
    func cutThroughToneDoesNotClick() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-cut-click-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await TestVideoFactory.make(segments: [(duration: 4, amplitude: 0.4)], to: url)
        // Второй кусок начинается на четверть периода тона 220 Гц позже:
        // на стыке волна скачет, как на настоящей склейке посреди звука.
        let clips = [
            Clip(sourceURL: url, start: 0, end: 1.5),
            Clip(sourceURL: url, start: 2 + 1.0 / 880, end: 3.5),
        ]

        let built = await CompositionBuilder.buildResult(clips: clips)
        let samples = try await mixedSamples(built.composition, try #require(built.audioMix))
        // Пустой или оборванный звук тоже «без щелчка» — поэтому длина проверяется явно.
        try #require(samples.count >= 3 * 48_000 - 480)

        let finding = SeamProbe.audio(samples: samples, sampleRate: 48_000, cutOffset: 1.5)
        #expect(!finding.click, "щелчок на склейке, clickRatio \(finding.clickRatio)")
        #expect(finding.dropoutMS == 0)
    }

    /// Звук склейки моно 48 кГц с применённым миксом — как его читает финальный экспорт.
    private func mixedSamples(_ composition: AVComposition, _ audioMix: AVAudioMix) async throws -> [Float] {
        let tracks = try await composition.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: composition)
        let output = AVAssetReaderAudioMixOutput(
            audioTracks: tracks,
            audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
        output.audioMix = audioMix
        reader.add(output)
        #expect(reader.startReading())
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            var chunk = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size)
            let copied = CMBlockBufferCopyDataBytes(
                block, atOffset: 0, dataLength: chunk.count * MemoryLayout<Float>.size, destination: &chunk)
            try #require(copied == kCMBlockBufferNoErr)
            samples += chunk
        }
        #expect(reader.status == .completed)
        return samples
    }

    @Test
    func testCompositionReportsMissingVideoInsteadOfSilentlySkippingIt() async {
        let clip = Clip(sourcePath: "/tmp/montazhka-definitely-missing.mov", start: 0, end: 5)

        let result = await CompositionBuilder.buildResult(clips: [clip])

        #expect(result.warnings.contains(.missingVideo(clip.fileName)))
        #expect(abs((result.composition.duration.seconds) - (0)) <= (0.001))
    }
}
