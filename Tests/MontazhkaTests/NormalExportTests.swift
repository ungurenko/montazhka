@preconcurrency import AVFoundation
import Foundation
import Testing

@testable import MontazhkaKit

/// Обычный (не шортс) проект: музыка стихает под речью, рядом с видео — .srt,
/// агент получает громкость и субтитры в ответе экспорта.
@Suite("Normal project export")
struct NormalExportTests {
    private struct Fixture {
        let root: URL
        let store: ProjectStore
        let project: Project
    }

    /// 12 секунд «речи»-тона с музыкой 30 % и приглушением; слова звучат 5,0–7,8 с.
    private func fixture(transcript: Bool) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-normal-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let video = root.appendingPathComponent("talk.mov")
        try await TestVideoFactory.make(segments: [(duration: 12, loud: true)], to: video)
        let store = ProjectStore(baseDirectory: root)
        let media = MediaReference(url: video)
        var project = Project(name: "Ролик", clips: [Clip(source: media, start: 0, end: 12)])
        let track = try #require(MusicLibrary.tracks.first)
        project.music = MusicSettings(enabled: true, trackID: track.id, volume: 30, eqEnabled: false, ducking: true)
        try await store.save(project)
        if transcript {
            let words = [
                TranscriptWord(sourceID: media.id, text: "Привет", start: 5.0, end: 5.4, confidence: 1),
                TranscriptWord(sourceID: media.id, text: "это", start: 5.6, end: 6.2, confidence: 1),
                TranscriptWord(sourceID: media.id, text: "проверка", start: 6.5, end: 7.8, confidence: 1),
            ]
            let cacheURL = await TranscriptStore(cacheDir: store.transcriptsDir, modelsDir: store.modelsDir)
                .cacheURL(for: media)
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(TranscriptDocument(words: words)).write(to: cacheURL)
        }
        return Fixture(root: root, store: store, project: project)
    }

    /// Громкость музыки (последний вход микса) в момент ленты.
    private func musicVolume(_ mix: AVAudioMix?, at seconds: Double) throws -> Float {
        let params = try #require(mix?.inputParameters.last)
        var start: Float = 0
        var end: Float = 0
        var range = CMTimeRange.zero
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        #expect(params.getVolumeRamp(for: time, startVolume: &start, endVolume: &end, timeRange: &range))
        let fraction = (time - range.start).seconds / max(0.001, range.duration.seconds)
        return start + (end - start) * Float(fraction)
    }

    @MainActor
    private func waitForPreview(_ controller: EditorController) async throws {
        for _ in 0..<500 where controller.previewState != .ready {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.previewState == .ready)
    }

    @MainActor
    @Test("with a transcript the window export ducks music under speech and carries subtitles")
    func windowDucksMusicUnderSpeech() async throws {
        let fixture = try await fixture(transcript: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let controller = EditorController(
            project: fixture.project, store: fixture.store, openRouterKeyStore: EmptyOpenRouterKeyStore())

        let prepared = try await controller.prepareExport(step: { _ in })

        #expect(abs(try musicVolume(prepared.audioMix, at: 6.5) - 0.3 * Float(MusicDucking.duckRatio)) < 0.01)
        #expect(abs(try musicVolume(prepared.audioMix, at: 3) - 0.3) < 0.01)
        #expect(prepared.subtitleCues?.map(\.text) == ["Привет это проверка"])
        #expect(prepared.subtitlesSkippedReason == nil)
        #expect(prepared.warning == nil)
        try await waitForPreview(controller)
        #expect(controller.previewSubtitleCues.map(\.text) == ["Привет это проверка"])
        #expect(controller.renderWarnings.isEmpty)
        await controller.shutdown()
    }

    @MainActor
    @Test("without a transcript or model the music stays level and both paths say why")
    func windowWithoutTranscriptExplains() async throws {
        let fixture = try await fixture(transcript: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let controller = EditorController(
            project: fixture.project, store: fixture.store, openRouterKeyStore: EmptyOpenRouterKeyStore())

        let prepared = try await controller.prepareExport(step: { _ in })

        #expect(abs(try musicVolume(prepared.audioMix, at: 6.5) - 0.3) < 0.01)
        #expect(prepared.subtitleCues == nil)
        #expect(prepared.subtitlesSkippedReason == "Нет модели распознавания — субтитры не созданы")
        #expect(prepared.warning == "Музыка не приглушается под голосом: нет расшифровки")
        try await waitForPreview(controller)
        #expect(controller.previewSubtitleCues.isEmpty)
        #expect(controller.renderWarnings == [.musicNotDucked])
        await controller.shutdown()
    }

    @Test("montazhka_export reports loudness, the .srt beside the file and next steps")
    func agentExportReportsLoudnessAndSubtitles() async throws {
        let fixture = try await fixture(transcript: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = AgentService(baseDirectory: fixture.root)

        let response = await service.export(
            projectID: fixture.project.id, outputPath: nil, quality: "compact",
            final: true, confirmFinal: true, overwrite: false)

        #expect(response.ok, "\(String(describing: response.error))")
        let data = try #require(response.data)
        guard case .object(let loudness)? = data["loudness"], case .number(let lufs)? = loudness["integratedLUFS"],
            case .number(let peak)? = loudness["truePeakDBTP"]
        else {
            Issue.record("нет громкости в ответе: \(data)")
            return
        }
        #expect(abs(lufs + 14) <= 0.5)
        #expect(peak <= -1)
        #expect(loudness["targetLUFS"] == .number(-14))
        #expect(loudness["normalized"] == .bool(true))
        #expect(loudness["targetMet"] == .bool(true))
        guard case .string(let path)? = data["path"] else {
            Issue.record("нет пути готового файла: \(data)")
            return
        }
        let video = URL(fileURLWithPath: path)
        #expect(video.lastPathComponent == "talk-montazhka.mp4")
        let subtitles = SubRipWriter.url(forVideo: video)
        #expect(data["subtitlesPath"] == .string(subtitles.path))
        #expect(FileManager.default.fileExists(atPath: subtitles.path))
        #expect(data["subtitlesSkippedReason"] == nil)
        #expect(data["warnings"] == .array([]))
        #expect(
            data["nextSteps"]
                == .array([
                    "montazhka_check projectId filePath — проверьте склейки готового файла",
                    "Критик: прочитайте ресурс montazhka://critic и запустите проверку отдельным субагентом",
                ]))
        #expect(await ExportProvenance.read(url: video) == AgentWordCuts.fingerprint(fixture.project.clips))
    }
}
