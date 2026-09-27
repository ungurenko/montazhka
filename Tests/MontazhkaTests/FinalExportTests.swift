@preconcurrency import AVFoundation
import Foundation
import Testing

@testable import MontazhkaKit

/// Завершающий шаг экспорта: громкость по стандарту, .srt рядом с видео, отпечаток ленты.
@Suite("Final export")
struct FinalExportTests {
    /// Синус −30 dBFS: тихо, до −14 LUFS нужно больше +10 дБ.
    private static let quietAmplitude = pow(10, -30.0 / 20)
    private static let seconds = 6.0

    private struct Fixture {
        let root: URL
        let video: URL
        let input: ExportInput
    }

    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-final-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let video = root.appendingPathComponent("tone.mov")
        try await TestVideoFactory.make(segments: [(duration: Self.seconds, amplitude: Self.quietAmplitude)], to: video)
        let built = await CompositionBuilder.build(clips: [Clip(sourceURL: video, start: 0, end: Self.seconds)])
        return Fixture(
            root: root, video: video, input: ExportInput(composition: built.composition, audioMix: built.audioMix))
    }

    private func cue(_ text: String, _ start: Double, _ end: Double) -> ShortsSubtitleCue {
        ShortsSubtitleCue(words: [ShortsSubtitleWord(text: text, start: start, end: end)], start: start, end: end)
    }

    private func job(
        _ input: ExportInput, cues: [ShortsSubtitleCue]?, reason: String? = nil, normalize: Bool
    ) -> FinalExportJob {
        FinalExportJob(
            input: input, quality: .compact, sizing: .quality(.compact), subtitleCues: cues,
            subtitlesSkippedReason: reason, normalizeLoudness: normalize, timelineFingerprint: "lenta-final")
    }

    @Test("a quiet video comes out at −14 LUFS with an .srt beside it and the timeline fingerprint")
    func mastersAndWritesSubtitles() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let output = fixture.root.appendingPathComponent("ролик.mp4")
        let cues = [cue("Первая", 0.5, 2), cue("Хвост", 5.5, 7), cue("За концом", 6.5, 8)]
        let stages = StageRecorder()

        let report = try await FinalExport.run(
            job(fixture.input, cues: cues, normalize: true), to: output, progress: { _ in },
            stage: { stages.append($0) })

        let loudness = try #require(report.loudness)
        let integrated = try #require(loudness.integratedLUFS)
        #expect(report.normalized)
        #expect(report.targetMet == true)
        #expect(abs(integrated + 14) <= 0.5, "громкость \(integrated) LUFS")
        #expect(loudness.truePeakDBTP <= -1.0, "пик \(loudness.truePeakDBTP) dBTP")
        #expect(report.gainDB > 10)
        #expect(report.warnings.isEmpty)
        #expect(stages.values == [.measuring, .mastering, .writing, .verifying])
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        #expect(abs(duration - Self.seconds) < 0.1)
        #expect(await ExportProvenance.read(url: output) == "lenta-final")

        let subtitles = SubRipWriter.url(forVideo: output)
        #expect(report.subtitlesURL == subtitles)
        #expect(report.subtitlesSkippedReason == nil)
        let text = try String(contentsOf: subtitles, encoding: .utf8)
        #expect(
            text == "1\n00:00:00,500 --> 00:00:02,000\nПервая\n\n2\n00:00:05,500 --> 00:00:06,000\nХвост\n",
            "фраза обрезана по концу ролика, фраза после конца выброшена")
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted()
        #expect(names == ["tone.mov", "ролик.mp4", "ролик.srt"], "временные файлы убраны")
    }

    @Test("re-exporting the same path without speech removes the old .srt; no mastering leaves the level alone")
    func reexportWithoutSpeech() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let output = fixture.root.appendingPathComponent("ролик.mp4")
        let subtitles = SubRipWriter.url(forVideo: output)
        try Data("1\n00:00:00,000 --> 00:00:01,000\nСтарое\n".utf8).write(to: subtitles)

        let report = try await FinalExport.run(
            job(fixture.input, cues: [], normalize: false), to: output, progress: { _ in })

        #expect(!FileManager.default.fileExists(atPath: subtitles.path))
        #expect(report.subtitlesURL == nil)
        #expect(report.subtitlesSkippedReason == "В ролике нет речи — субтитры не созданы")
        #expect(!report.normalized)
        #expect(report.targetMet == nil)
        #expect(report.gainDB == 0)
        let integrated = try #require(report.loudness?.integratedLUFS)
        let source = try #require(try await LoudnessMeter.measure(url: fixture.video).integratedLUFS)
        #expect(abs(integrated - source) < 0.5, "громкость не тронута: \(integrated) LUFS, в исходнике \(source)")
    }
}

/// Этапы приходят с фоновых потоков.
private final class StageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stages: [FinalExportStage] = []

    var values: [FinalExportStage] { lock.withLock { stages } }

    func append(_ stage: FinalExportStage) { lock.withLock { stages.append(stage) } }
}
