@preconcurrency import AVFoundation
import Foundation
import Testing

@testable import MontazhkaKit

/// Экспорт никогда не пишет поверх своих входов: исходного видео, музыки, анимаций —
/// ни по тому же пути, ни через символическую ссылку. Окно, агент и завершающий шаг.
@Suite("Export never overwrites its inputs")
struct ExportDestinationGuardTests {
    private struct Fixture {
        let root: URL
        let video: URL
        let input: ExportInput
    }

    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let video = root.appendingPathComponent("source.mp4")
        try await TestVideoFactory.make(segments: [(duration: 1, loud: true)], to: video)
        let built = await CompositionBuilder.build(clips: [Clip(sourceURL: video, start: 0, end: 1)])
        return Fixture(
            root: root, video: video, input: ExportInput(composition: built.composition, audioMix: built.audioMix))
    }

    private func job(_ input: ExportInput, protecting inputs: [URL] = []) -> FinalExportJob {
        var job = FinalExportJob(
            input: input, quality: .compact, sizing: .quality(.compact), subtitleCues: nil,
            subtitlesSkippedReason: nil, normalizeLoudness: false, projectFingerprint: nil)
        job.protectedInputs = inputs
        return job
    }

    @Test("exporting onto the source video is refused and the source stays byte for byte")
    func refusesTheSourceVideo() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let before = try Data(contentsOf: fixture.video)

        await #expect(throws: ExportDestinationError.self) {
            _ = try await FinalExport.run(job(fixture.input), to: fixture.video, progress: { _ in })
        }

        #expect(try Data(contentsOf: fixture.video) == before)
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        #expect(names == ["source.mp4"], "ни временных файлов, ни .srt")
    }

    @Test("a symbolic link to the source is the source too")
    func refusesASymlinkToTheSource() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let link = fixture.root.appendingPathComponent("ярлык.mp4")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.video)
        let before = try Data(contentsOf: fixture.video)

        await #expect(throws: ExportDestinationError.self) {
            _ = try await FinalExport.run(job(fixture.input), to: link, progress: { _ in })
        }

        #expect(try Data(contentsOf: fixture.video) == before)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == fixture.video.path)
    }

    @Test("an input the composition does not read directly (the original music file) is protected as well")
    func refusesAProtectedInput() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let music = fixture.root.appendingPathComponent("music.mp4")
        try Data("моя музыка".utf8).write(to: music)

        await #expect(throws: ExportDestinationError.self) {
            _ = try await FinalExport.run(job(fixture.input, protecting: [music]), to: music, progress: { _ in })
        }

        #expect(try String(contentsOf: music, encoding: .utf8) == "моя музыка")
    }

    @Test("a hard link to the source shares its bytes and is refused")
    func refusesAHardLinkToTheSource() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let twin = fixture.root.appendingPathComponent("twin.mp4")
        try FileManager.default.linkItem(at: fixture.video, to: twin)
        let before = try Data(contentsOf: fixture.video)

        await #expect(throws: ExportDestinationError.self) {
            _ = try await FinalExport.run(job(fixture.input), to: twin, progress: { _ in })
        }

        #expect(try Data(contentsOf: fixture.video) == before)
    }

    @Test("the project lists its clips, custom music and animation files as inputs")
    func projectInputFiles() {
        let clip = URL(fileURLWithPath: "/tmp/guard/clip.mov")
        let song = URL(fileURLWithPath: "/tmp/guard/song.m4a")
        let overlay = URL(fileURLWithPath: "/tmp/guard/overlay.mov")
        var project = Project(name: "Входы", clips: [Clip(sourceURL: clip, start: 0, end: 1)])
        project.music = MusicSettings(enabled: true, customMedia: MediaReference(path: song.path))
        project.overlays = [
            ProjectOverlay(
                id: UUID(), media: MediaReference(path: overlay.path),
                anchor: OverlayAnchor(sourceID: project.clips[0].source.id, sourceTime: 0, wordText: nil),
                align: .start, payoffAt: 0, duration: 1, position: .full, scale: 1)
        ]

        #expect(Set(project.exportInputFiles.map(\.path)) == [clip.path, song.path, overlay.path])
    }

    @MainActor
    @Test("the export window refuses the source path before any preparation starts")
    func windowRefusesBeforePreparation() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let preparer = CountingPreparer(inputs: [fixture.video])
        let model = ExportModel()

        model.start(preparer: preparer, quality: .compact, to: fixture.video)
        for _ in 0..<100 where !isFailed(model.state) { try await Task.sleep(for: .milliseconds(10)) }

        #expect(isFailed(model.state))
        #expect(preparer.calls == 0, "дорогая подготовка не запускалась")
    }

    @Test("the agent refuses to export onto the project's custom music file")
    func agentRefusesTheMusicFile() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let song = fixture.root.appendingPathComponent("song.m4a")
        try Data("песня".utf8).write(to: song)
        let store = ProjectStore(baseDirectory: fixture.root)
        var project = Project(name: "Ролик", clips: [Clip(sourceURL: fixture.video, start: 0, end: 1)])
        project.music = MusicSettings(enabled: true, customMedia: MediaReference(path: song.path))
        try await store.save(project)

        let response = await AgentService(baseDirectory: fixture.root).export(
            projectID: project.id, outputPath: song.path, quality: "compact",
            final: false, confirmFinal: false, overwrite: true)

        #expect(!response.ok)
        #expect(response.error?.code == String(describing: ExportDestinationError.self))
        #expect(try String(contentsOf: song, encoding: .utf8) == "песня")
    }

    private func isFailed(_ state: ExportModel.State) -> Bool {
        if case .failed = state { return true }
        return false
    }
}

@MainActor
private final class CountingPreparer: ExportPreparing {
    let exportInputFiles: [URL]
    private(set) var calls = 0

    init(inputs: [URL]) { exportInputFiles = inputs }

    func prepareExport(step: @escaping @Sendable (ExportPreparationStep) -> Void) async throws -> PreparedExport {
        calls += 1
        return PreparedExport(composition: AVMutableComposition(), audioMix: nil, warning: nil)
    }
}
