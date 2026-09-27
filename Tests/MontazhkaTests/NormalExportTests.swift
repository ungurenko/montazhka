@preconcurrency import AVFoundation
import Foundation
import Testing

@testable import MontazhkaKit

/// Обычный (не шортс) проект: рядом с видео — .srt, агент получает громкость
/// и субтитры в ответе экспорта.
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
