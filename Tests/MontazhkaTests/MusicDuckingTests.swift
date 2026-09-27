import AVFoundation
import Foundation
import Testing

@testable import MontazhkaKit

@Suite("Music ducking")
struct MusicDuckingTests {
    /// Громкость между ключевыми точками меняется линейно — так же, как рампы AVAudioMix.
    private func volume(at time: Double, _ points: [MusicDucking.Point]) -> Double {
        guard let first = points.first, time > first.time else { return points.first?.volume ?? 0 }
        for (a, b) in zip(points, points.dropFirst()) where time <= b.time {
            let span = b.time - a.time
            return span <= 0 ? b.volume : a.volume + (b.volume - a.volume) * (time - a.time) / span
        }
        return points.last?.volume ?? 0
    }

    @Test("without speech the music only fades in and out")
    func noSpeech() {
        let points = MusicDucking.envelope(speech: [], total: 20, level: 0.3)
        #expect(volume(at: 0, points) == 0)
        #expect(abs(volume(at: 10, points) - 0.3) < 0.001)
        #expect(volume(at: 20, points) == 0)
    }

    @Test("music drops under speech and comes back in the pause")
    func ducksUnderSpeech() {
        let speech = [TimelineRange(from: 5, to: 8)]
        let points = MusicDucking.envelope(speech: speech, total: 20, level: 0.3)
        #expect(abs(volume(at: 6.5, points) - 0.3 * MusicDucking.duckRatio) < 0.001)
        #expect(abs(volume(at: 3, points) - 0.3) < 0.001)
        #expect(abs(volume(at: 12, points) - 0.3) < 0.001)
    }

    @Test("short breaths between phrases do not pump the music")
    func shortGapsStayDucked() {
        let speech = [TimelineRange(from: 5, to: 8), TimelineRange(from: 8.3, to: 11)]
        let points = MusicDucking.envelope(speech: speech, total: 20, level: 0.3)
        #expect(abs(volume(at: 8.15, points) - 0.3 * MusicDucking.duckRatio) < 0.001)
    }

    @Test("keyframes never go back in time")
    func monotonic() {
        let speech = [TimelineRange(from: 0, to: 2), TimelineRange(from: 3, to: 19.9)]
        let points = MusicDucking.envelope(speech: speech, total: 20, level: 0.3)
        for (a, b) in zip(points, points.dropFirst()) { #expect(a.time <= b.time) }
        #expect(points.allSatisfy { $0.volume >= 0 && $0.volume <= 0.3 + 0.0001 })
    }
}

@Suite("Music ducking in the pipeline")
struct MusicDuckingPipelineTests {
    private func musicVolume(at seconds: Double, ducking: Bool) async throws -> Float {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("talk.mov")
        try await TestVideoFactory.make(segments: [(duration: 12, loud: true)], to: video)
        let track = try #require(MusicLibrary.tracks.first)
        var project = Project(name: "Шортс", clips: [Clip(sourceURL: video, start: 0, end: 12)])
        project.music = MusicSettings(enabled: true, trackID: track.id, volume: 30, eqEnabled: false, ducking: ducking)

        let pipeline = MediaPipeline(
            voiceStore: VoiceEnhanceStore(cacheDir: root), musicEQStore: MusicEQStore(cacheDir: root))
        let result = await pipeline.render(
            MediaRenderRequest(
                project: project, mode: .export, readyEnhancedAudio: [:],
                speechRanges: [TimelineRange(from: 5, to: 8)]))
        let params = try #require(result.audioMix?.inputParameters.last)
        var start: Float = 0
        var end: Float = 0
        var range = CMTimeRange.zero
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        #expect(params.getVolumeRamp(for: time, startVolume: &start, endVolume: &end, timeRange: &range))
        let fraction = (time - range.start).seconds / max(0.001, range.duration.seconds)
        return start + (end - start) * Float(fraction)
    }

    @Test("a ducking draft lowers the music under speech")
    func ducksWhenAsked() async throws {
        let underSpeech = try await musicVolume(at: 6.5, ducking: true)
        let inPause = try await musicVolume(at: 3, ducking: true)
        #expect(abs(underSpeech - 0.3 * Float(MusicDucking.duckRatio)) < 0.01)
        #expect(abs(inPause - 0.3) < 0.01)
    }

    @Test("a regular project keeps music level even when speech is known")
    func noDuckingByDefault() async throws {
        #expect(abs(try await musicVolume(at: 6.5, ducking: false) - 0.3) < 0.01)
    }
}

/// Музыка, включённая в окне или агентом, стихает под голосом; сохранённый выбор не трогается.
@Suite("Music ducking defaults")
struct MusicDuckingDefaultsTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-ducking-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @MainActor
    @Test("turning music on in the editor turns ducking on; a saved project's choice stays")
    func editorTurnsDuckingOn() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = EditorController(
            project: Project(name: "Музыка"), store: ProjectStore(baseDirectory: root),
            openRouterKeyStore: EmptyOpenRouterKeyStore())
        var music = controller.project.music
        music.enabled = true

        controller.updateMusicSettings(music)

        #expect(controller.project.music.enabled)
        #expect(controller.project.music.ducking)
        await controller.shutdown()

        var saved = Project(name: "Сохранённый")
        saved.music = MusicSettings(enabled: true, volume: 30, ducking: false)
        let reopened = EditorController(
            project: saved, store: ProjectStore(baseDirectory: root), openRouterKeyStore: EmptyOpenRouterKeyStore())
        var louder = reopened.project.music
        louder.volume = 40

        reopened.updateMusicSettings(louder)

        #expect(reopened.project.music.volume == 40)
        #expect(!reopened.project.music.ducking, "выбор сохранённого проекта не меняется молча")
        await reopened.shutdown()
    }

    @Test("edit_video with musicPath ducks the music under speech")
    func agentMusicDucks() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("talk.mov")
        try await TestVideoFactory.make(segments: [(duration: 2, loud: true)], to: video)
        let service = AgentService(baseDirectory: root)

        let response = await service.edit(
            AgentEditRequest(
                sourcePaths: [video.path], removePauses: false, enhanceVoice: false, musicPath: video.path))

        guard case .string(let id)? = response.data?["projectId"], let projectID = UUID(uuidString: id) else {
            Issue.record("проект не создан: \(String(describing: response.error))")
            return
        }
        let project = try await service.store.load(id: projectID)
        #expect(project.music.enabled)
        #expect(project.music.ducking)
    }
}
