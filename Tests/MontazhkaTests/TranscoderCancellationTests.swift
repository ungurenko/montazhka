@preconcurrency import AVFoundation
import Foundation
import Testing
import os

@testable import MontazhkaKit

@Suite("Transcoder cancellation")
struct TranscoderCancellationTests {
    private let settings = Transcoder.Settings(
        dimensions: CGSize(width: 320, height: 180), videoBitrate: 500_000, audioBitrate: 128_000)

    private func fixture(audio: Bool) async throws -> (URL, ExportInput) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            let source = root.appendingPathComponent("source.mov")
            try await TestVideoFactory.make(segments: [(duration: 3, loud: true)], to: source)
            let asset = AVURLAsset(url: source)
            let composition = AVMutableComposition()
            let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 3, preferredTimescale: 600))
            for type in audio ? [AVMediaType.video, .audio] : [.video] {
                let track = try #require(try await asset.loadTracks(withMediaType: type).first)
                let target = try #require(composition.addMutableTrack(withMediaType: type, preferredTrackID: 0))
                try target.insertTimeRange(range, of: track, at: .zero)
            }
            return (root, ExportInput(composition: composition, audioMix: nil))
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    @Test("ordinary export keeps duration and expected tracks", arguments: [false, true])
    func ordinaryExport(audio: Bool) async throws {
        let (root, input) = try await fixture(audio: audio)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("result.mp4")
        try await Transcoder.export(input: input, settings: settings, to: url, progress: { _ in })
        let asset = AVURLAsset(url: url)
        #expect(abs(try await asset.load(.duration).seconds - 3) < 0.1)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == (audio ? 1 : 0))
    }

    @Test("cancel during pumping finishes and preserves the destination", arguments: [false, true])
    func cancelDuringExport(audio: Bool) async throws {
        let (root, input) = try await fixture(audio: audio)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("result.mp4")
        let previous = Data("previous export".utf8)
        try previous.write(to: url)
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let first = OSAllocatedUnfairLock(initialState: true)
        let settings = settings
        let task = Task {
            try await Transcoder.export(input: input, settings: settings, to: url) { _ in
                let block = first.withLock { value in
                    defer { value = false }
                    return value
                }
                if block {
                    started.signal()
                    _ = release.wait(timeout: .now() + 5)
                }
            }
        }
        let pumping = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: started.wait(timeout: .now() + 10) == .success)
            }
        }
        #expect(pumping)
        task.cancel()
        task.cancel()
        release.signal()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(try Data(contentsOf: url) == previous)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == ["source.mov", "result.mp4"])
    }

    @Test("an already cancelled export leaves no file")
    func cancelBeforeExport() async throws {
        let (root, input) = try await fixture(audio: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = settings
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await Transcoder.export(
                input: input, settings: settings, to: root.appendingPathComponent("result.mp4"), progress: { _ in })
        }
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["source.mov"])
    }
}
