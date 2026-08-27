import AVFoundation
import Foundation
import Testing

@testable import MontazhkaKit

@Suite
struct AtomicMediaOutputTests {
    @Test
    func failedExportKeepsExistingDestinationAndRemovesTemporaryFile() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("video.mp4")
        try Data("old".utf8).write(to: destination)

        let output = AtomicMediaOutput(destinationURL: destination)
        try Data("partial".utf8).write(to: output.temporaryURL)
        output.discard()

        #expect(try Data(contentsOf: destination) == Data("old".utf8))
        #expect(!FileManager.default.fileExists(atPath: output.temporaryURL.path))
    }

    @Test
    func successfulExportAtomicallyReplacesExistingDestination() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("video.mp4")
        try Data("old".utf8).write(to: destination)

        var output = AtomicMediaOutput(destinationURL: destination)
        try Data("complete".utf8).write(to: output.temporaryURL)
        try output.commit()
        output.discard()

        #expect(try Data(contentsOf: destination) == Data("complete".utf8))
        #expect(!FileManager.default.fileExists(atPath: output.temporaryURL.path))
    }

    @Test
    func successfulExportMovesIntoEmptyDestination() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("video.mp4")

        var output = AtomicMediaOutput(destinationURL: destination)
        try Data("complete".utf8).write(to: output.temporaryURL)
        try output.commit()

        #expect(try Data(contentsOf: destination) == Data("complete".utf8))
    }

    @Test
    func transcoderFailureDoesNotTouchExistingDestination() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("video.mp4")
        try Data("old".utf8).write(to: destination)

        await #expect(throws: TranscodeError.self) {
            try await Transcoder.export(
                input: ExportInput(composition: AVMutableComposition(), audioMix: nil),
                settings: Transcoder.Settings(
                    dimensions: CGSize(width: 640, height: 360),
                    videoBitrate: 1_000_000,
                    audioBitrate: 96_000),
                to: destination,
                progress: { _ in })
        }

        #expect(try Data(contentsOf: destination) == Data("old".utf8))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-atomic-output-\(UUID().uuidString)", isDirectory: true)
    }
}
