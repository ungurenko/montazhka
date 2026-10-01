import Foundation
import Testing

@testable import MontazhkaKit

@MainActor
@Suite
struct EditorClipImportTests {
    @Test("parallel imports preserve input order and group successful clips into one undo step")
    func orderedPartialImport() async throws {
        try await EditorBackgroundWorkFixture.run { fixture in
            let gate = fixture.gate()
            let urls = ["first.mov", "broken.mov", "last.mov"].map { fixture.root.appendingPathComponent($0) }
            let controller = fixture.editor(read: { index, url in
                await gate.wait(url.lastPathComponent)
                await gate.didFinish(url.lastPathComponent)
                return ClipLoadResult(
                    index: index, url: url,
                    duration: index == 1 ? nil : Double(index + 1),
                    error: index == 1 ? "не читается" : nil)
            })
            controller.addClips(urls: urls)
            #expect(controller.clipImportState == .importing)
            for url in urls { try await gate.waitForStart(url.lastPathComponent) }
            for url in urls.reversed() {
                await gate.open(url.lastPathComponent)
                try await gate.waitForFinish(url.lastPathComponent)
            }
            try await EditorBackgroundWorkFixture.waitUntil { controller.clipImportState != .importing }

            #expect(controller.project.clips.map { $0.source.displayName } == ["first.mov", "last.mov"])
            #expect(controller.project.clips.map(\.duration) == [1, 3])
            guard case .failed(let error) = controller.clipImportState else {
                Issue.record("частичная ошибка импорта должна быть видна")
                return
            }
            #expect(error.what == "Не получилось добавить видео.")
            #expect(error.hint == "«broken.mov»: не читается")
            #expect(controller.canUndo)
            controller.undo()
            #expect(controller.project.clips.isEmpty)
            #expect(!controller.canUndo)
        }
    }

    @Test("a replaced or closed import cannot apply its late result", arguments: [false, true])
    func cancelledImportCannotApply(closing: Bool) async throws {
        try await EditorBackgroundWorkFixture.run { fixture in
            let gate = fixture.gate()
            let old = fixture.root.appendingPathComponent("old.mov")
            let latest = fixture.root.appendingPathComponent("latest.mov")
            let controller = fixture.editor(read: { index, url in
                await gate.wait(url.lastPathComponent)
                await gate.didFinish(url.lastPathComponent)
                return ClipLoadResult(index: index, url: url, duration: 1, error: nil)
            })
            controller.addClips(urls: [old])
            try await gate.waitForStart("old.mov")
            if closing {
                await controller.shutdown()
            } else {
                controller.addClips(urls: [latest])
                try await gate.waitForStart("latest.mov")
                await gate.open("latest.mov")
                try await EditorBackgroundWorkFixture.waitUntil { controller.clipImportState == .idle }
            }
            await gate.open("old.mov")
            try await gate.waitForFinish("old.mov")
            try await Task.sleep(for: .milliseconds(30))

            #expect(controller.project.clips.map { $0.source.displayName } == (closing ? [] : ["latest.mov"]))
            #expect(controller.clipImportState == .idle)
            if closing { #expect(controller.player.currentItem == nil) }
        }
    }

    @Test("the import rejects exactly 0.1 seconds and accepts a longer video", arguments: [0.1, 0.2])
    func durationBoundary(duration: Double) async throws {
        try await EditorBackgroundWorkFixture.run { fixture in
            let url = try await fixture.video(duration: duration)
            let controller = fixture.editor()
            controller.addClips(urls: [url])
            try await EditorBackgroundWorkFixture.waitUntil { controller.clipImportState != .importing }
            #expect(controller.project.clips.count == (duration > 0.1 ? 1 : 0))
            if duration == 0.1 {
                guard case .failed(let error) = controller.clipImportState else {
                    Issue.record("видео длиной 0,1 секунды должно быть отклонено")
                    return
                }
                #expect(error.hint == "«source.mov»: не удалось определить длительность")
            } else {
                #expect(controller.clipImportState == .idle)
            }
        }
    }

    @Test("an audio-only file is rejected without creating undo history")
    func audioOnlyFile() async throws {
        try await EditorBackgroundWorkFixture.run { fixture in
            let url = fixture.root.appendingPathComponent("sound.caf")
            try EditorBackgroundWorkFixture.writeAudio(to: url)
            let controller = fixture.editor()
            controller.addClips(urls: [url])
            try await EditorBackgroundWorkFixture.waitUntil { controller.clipImportState != .importing }
            guard case .failed(let error) = controller.clipImportState else {
                Issue.record("файл без видео должен быть отклонён")
                return
            }
            #expect(error.hint == "«sound.caf»: в файле нет видеодорожки")
            #expect(controller.project.clips.isEmpty)
            #expect(!controller.canUndo)
        }
    }
}
