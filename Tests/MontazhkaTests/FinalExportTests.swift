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

    /// Ролик без звуковой дорожки — как запись экрана без микрофона.
    private func silentVideo(seconds: Double, in root: URL) async throws -> URL {
        let url = root.appendingPathComponent("screen.mov")
        let (width, height) = (320, 180)
        let frame = try TestOverlayFactory.pixelBuffer(width: width, height: height, format: kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(frame, [])
        memset(CVPixelBufferGetBaseAddress(frame), 0x40, CVPixelBufferGetDataSize(frame))
        CVPixelBufferUnlockBaseAddress(frame, [])
        try await TestOverlayFactory.writeStill(
            frame,
            settings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height],
            fileType: .mov, frameCount: Int(seconds * 30), frameDuration: CMTime(value: 1, timescale: 30), to: url)
        return url
    }

    private func cue(_ text: String, _ start: Double, _ end: Double) -> ShortsSubtitleCue {
        ShortsSubtitleCue(words: [ShortsSubtitleWord(text: text, start: start, end: end)], start: start, end: end)
    }

    private func job(
        _ input: ExportInput, cues: [ShortsSubtitleCue]?, reason: String? = nil, normalize: Bool
    ) -> FinalExportJob {
        FinalExportJob(
            input: input, quality: .compact, sizing: .quality(.compact), subtitleCues: cues,
            subtitlesSkippedReason: reason, normalizeLoudness: normalize, projectFingerprint: "lenta-final")
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

    @Test("re-exporting the same path without speech removes our old .srt; no mastering leaves the level alone")
    func reexportWithoutSpeech() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let output = fixture.root.appendingPathComponent("ролик.mp4")
        let subtitles = SubRipWriter.url(forVideo: output)
        _ = try await FinalExport.run(
            job(fixture.input, cues: [cue("Старое", 0, 1)], normalize: false), to: output, progress: { _ in })
        #expect(FileManager.default.fileExists(atPath: subtitles.path))

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

extension FinalExportTests {
    @Test("a video without sound exports with loudness on as before: untouched, no warning")
    func videoWithoutSound() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let silent = try await silentVideo(seconds: 2, in: fixture.root)
        let built = await CompositionBuilder.build(clips: [Clip(sourceURL: silent, start: 0, end: 2)])
        let output = fixture.root.appendingPathComponent("экран.mp4")

        let report = try await FinalExport.run(
            job(ExportInput(composition: built.composition, audioMix: built.audioMix), cues: nil, normalize: true),
            to: output, progress: { _ in })

        #expect(!report.normalized)
        #expect(report.loudness == nil)
        #expect(report.targetMet == nil)
        #expect(report.gainDB == 0)
        #expect(report.warnings.isEmpty)
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        #expect(abs(duration - 2) < 0.1)
    }

    @Test("a silent clip beside a voiced one and a silent video under music are still mastered")
    func silentPartsWithSound() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let silent = try await silentVideo(seconds: 2, in: fixture.root)
        let mixed = await CompositionBuilder.build(clips: [
            Clip(sourceURL: silent, start: 0, end: 2), Clip(sourceURL: fixture.video, start: 0, end: Self.seconds),
        ])
        let underMusic = await CompositionBuilder.build(
            clips: [Clip(sourceURL: silent, start: 0, end: 2)], music: MusicInput(url: fixture.video, volume: 1))

        for (name, built) in [("склейка", mixed), ("музыка", underMusic)] {
            let report = try await FinalExport.run(
                job(ExportInput(composition: built.composition, audioMix: built.audioMix), cues: nil, normalize: true),
                to: fixture.root.appendingPathComponent("\(name).mp4"), progress: { _ in })
            #expect(report.normalized, "\(name): звук выровнен")
            #expect(report.loudness?.integratedLUFS != nil, "\(name): громкость замерена")
        }
    }
}

/// Чей .srt лежит рядом: свой прошлый (MP4 уже был) или чужой (MP4 ещё не было).
extension FinalExportTests {
    private static let userSubtitles = "1\n00:00:00,000 --> 00:00:01,000\nМои субтитры\n"

    @Test("a new export never replaces or deletes a .srt that was there before any MP4", arguments: [true, false])
    func userSubtitlesStay(withSpeech: Bool) async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let output = fixture.root.appendingPathComponent("ролик.mp4")
        let subtitles = SubRipWriter.url(forVideo: output)
        try Data(Self.userSubtitles.utf8).write(to: subtitles)

        let report = try await FinalExport.run(
            job(fixture.input, cues: withSpeech ? [cue("Первая", 0.5, 2)] : [], normalize: false), to: output,
            progress: { _ in })

        #expect(try String(contentsOf: subtitles, encoding: .utf8) == Self.userSubtitles)
        #expect(report.subtitlesURL == nil)
        #expect(
            report.subtitlesSkippedReason
                == (withSpeech
                    ? "Рядом уже есть файл субтитров ролик.srt — не стал его заменять"
                    : "В ролике нет речи — субтитры не созданы"))
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted()
        #expect(names == ["tone.mov", "ролик.mp4", "ролик.srt"], "временные файлы убраны")
    }

    @Test("re-exporting over our own MP4 replaces its untouched .srt with the new phrases")
    func reexportReplacesOwnSubtitles() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let output = fixture.root.appendingPathComponent("ролик.mp4")
        let subtitles = SubRipWriter.url(forVideo: output)
        _ = try await FinalExport.run(
            job(fixture.input, cues: [cue("Старое", 0, 1)], normalize: false), to: output, progress: { _ in })

        let report = try await FinalExport.run(
            job(fixture.input, cues: [cue("Первая", 0.5, 2)], normalize: false), to: output, progress: { _ in })

        #expect(report.subtitlesURL == subtitles)
        #expect(try String(contentsOf: subtitles, encoding: .utf8) == "1\n00:00:00,500 --> 00:00:02,000\nПервая\n")
    }

    @Test("when our .srt cannot be put in place, the previous one stays")
    func failedSubtitlesKeepPreviousFile() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let output = fixture.root.appendingPathComponent("ролик.mp4")
        let subtitles = SubRipWriter.url(forVideo: output)
        _ = try await FinalExport.run(
            job(fixture.input, cues: [cue("Старое", 0, 1)], normalize: false), to: output, progress: { _ in })
        let previous = try String(contentsOf: subtitles, encoding: .utf8)
        let root = fixture.root

        // Пока пишется видео, временный .srt пропадает — записать субтитры не выйдет.
        let report = try await FinalExport.run(
            job(fixture.input, cues: [cue("Первая", 0.5, 2)], normalize: false), to: output, progress: { _ in },
            stage: { stage in
                guard stage == .writing else { return }
                let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
                for name in names where name.hasPrefix(".ролик.montazhka-") && name.hasSuffix(".srt") {
                    try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
                }
            })

        #expect(report.subtitlesURL == nil)
        #expect(report.subtitlesSkippedReason?.hasPrefix("Субтитры не сохранились: ") == true)
        #expect(try String(contentsOf: subtitles, encoding: .utf8) == previous)
    }

    @Test("a .srt that appears during the export and cannot be read is not replaced")
    func unreadableSubtitlesStay() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let output = fixture.root.appendingPathComponent("ролик.mp4")
        let subtitles = SubRipWriter.url(forVideo: output)
        let path = subtitles.path
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path) }

        let report = try await FinalExport.run(
            job(fixture.input, cues: [cue("Первая", 0.5, 2)], normalize: false), to: output, progress: { _ in },
            stage: { stage in
                guard stage == .writing else { return }
                FileManager.default.createFile(
                    atPath: path, contents: Data(Self.userSubtitles.utf8), attributes: [.posixPermissions: 0o000])
            })

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        #expect(try String(contentsOf: subtitles, encoding: .utf8) == Self.userSubtitles)
        #expect(report.subtitlesURL == nil)
        #expect(
            report.subtitlesSkippedReason == "Рядом уже есть файл субтитров ролик.srt — не стал его заменять",
            "чужой файл узнан, а не принят за пустое место")
    }

    @Test("someone else's MP4 with its .srt: the .srt stays when the video is replaced", arguments: [true, false])
    func foreignPairKeepsSubtitles(withSpeech: Bool) async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let output = fixture.root.appendingPathComponent("ролик.mp4")
        let subtitles = SubRipWriter.url(forVideo: output)
        try Data("чужое видео".utf8).write(to: output)
        try Data(Self.userSubtitles.utf8).write(to: subtitles)

        let report = try await FinalExport.run(
            job(fixture.input, cues: withSpeech ? [cue("Первая", 0.5, 2)] : [], normalize: false), to: output,
            progress: { _ in })

        #expect(try String(contentsOf: subtitles, encoding: .utf8) == Self.userSubtitles)
        #expect(report.subtitlesURL == nil)
        #expect(
            report.subtitlesSkippedReason?.contains("ролик.srt") == true
                || report.warnings.contains { $0.contains("ролик.srt") },
            "человек узнаёт, что рядом остались прежние субтитры")
    }

    @Test("our own .srt edited by hand after the export is neither replaced nor deleted", arguments: [true, false])
    func editedOwnSubtitlesStay(withSpeech: Bool) async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let output = fixture.root.appendingPathComponent("ролик.mp4")
        let subtitles = SubRipWriter.url(forVideo: output)
        _ = try await FinalExport.run(
            job(fixture.input, cues: [cue("Старое", 0, 1)], normalize: false), to: output, progress: { _ in })
        let edited = "1\n00:00:00,000 --> 00:00:01,000\nПоправил руками\n"
        try Data(edited.utf8).write(to: subtitles)

        let report = try await FinalExport.run(
            job(fixture.input, cues: withSpeech ? [cue("Первая", 0.5, 2)] : [], normalize: false), to: output,
            progress: { _ in })

        #expect(try String(contentsOf: subtitles, encoding: .utf8) == edited)
        #expect(report.subtitlesURL == nil)
        #expect(
            report.subtitlesSkippedReason?.contains("ролик.srt") == true
                || report.warnings.contains { $0.contains("ролик.srt") })
    }

    @Test("cancel during the final loudness check leaves the previous MP4 and .srt in place")
    func cancelDuringMeasurementKeepsPreviousFiles() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let output = fixture.root.appendingPathComponent("ролик.mp4")
        let subtitles = SubRipWriter.url(forVideo: output)
        let previous = Data("прошлый экспорт".utf8)
        try previous.write(to: output)
        try Data(Self.userSubtitles.utf8).write(to: subtitles)
        let exportJob = job(fixture.input, cues: [cue("Первая", 0.5, 2)], normalize: true)

        let export = Task {
            try await FinalExport.run(
                exportJob, to: output, progress: { _ in },
                stage: { stage in
                    guard stage == .verifying else { return }
                    withUnsafeCurrentTask { $0?.cancel() }
                })
        }
        let result = await export.result

        #expect(throws: CancellationError.self) { try result.get() }
        #expect(try Data(contentsOf: output) == previous)
        #expect(try String(contentsOf: subtitles, encoding: .utf8) == Self.userSubtitles)
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted()
        #expect(names == ["tone.mov", "ролик.mp4", "ролик.srt"], "временные файлы убраны")
    }
}

/// Этапы приходят с фоновых потоков.
private final class StageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stages: [FinalExportStage] = []

    var values: [FinalExportStage] { lock.withLock { stages } }

    func append(_ stage: FinalExportStage) { lock.withLock { stages.append(stage) } }
}
