@preconcurrency import AVFoundation
import CoreVideo
import Foundation
import Testing

@testable import MontazhkaKit

/// Файл анимации проверяется до того, как попасть в проект: без прозрачности
/// он закрыл бы видео целиком, а webm Монтажка не читает вовсе.
@Suite("Overlay media probe")
struct OverlayMediaProbeTests {
    private let projectFrame = CGSize(width: 1920, height: 1080)

    private struct WriteFailure: Error {
        let reason: String
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-overlay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Текст отказа проверки или nil, если файл принят.
    private func rejection(_ url: URL) async -> String? {
        do {
            _ = try await OverlayMediaProbe.validate(url, projectFrame: projectFrame)
            return nil
        } catch AgentServiceError.invalidInput(let message) {
            return message
        } catch {
            return "unexpected error: \(error)"
        }
    }

    /// Кадр BGRA: белый квадрат в центре на прозрачном (или чёрном непрозрачном) фоне.
    private func frame(width: Int, height: Int, transparent: Bool) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &created)
        guard let buffer = created else { throw WriteFailure(reason: "pixel buffer") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else {
            throw WriteFailure(reason: "pixel memory")
        }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let inSquare = x >= width / 4 && x < width * 3 / 4 && y >= height / 4 && y < height * 3 / 4
                let pixel = base + y * rowBytes + x * 4
                let colour: UInt8 = inSquare ? 255 : 0
                pixel[0] = colour
                pixel[1] = colour
                pixel[2] = colour
                pixel[3] = inSquare || !transparent ? 255 : 0
            }
        }
        return buffer
    }

    /// Пишет ролик ProRes 4444 из одинаковых кадров, 10 кадров в секунду.
    private func writeProRes(
        to url: URL, width: Int = 160, height: Int = 90, seconds: Double = 1, transparent: Bool = true
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.proRes4444, AVVideoWidthKey: width, AVVideoHeightKey: height,
            ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? WriteFailure(reason: "start") }
        writer.startSession(atSourceTime: .zero)

        let picture = try frame(width: width, height: height, transparent: transparent)
        let fps: Int32 = 10
        let frames = max(1, Int((seconds * Double(fps)).rounded()))
        let deadline = Date().addingTimeInterval(30)
        for index in 0..<frames {
            while !input.isReadyForMoreMediaData {
                // Писатель бывает замолкает: лучше громко упасть, чем повиснуть.
                guard Date() < deadline else { throw WriteFailure(reason: "writer stalled") }
                try await Task.sleep(for: .milliseconds(2))
            }
            guard adaptor.append(picture, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: fps))
            else { throw writer.error ?? WriteFailure(reason: "append") }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: fps))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? WriteFailure(reason: "finish") }
    }

    @Test("a ProRes 4444 clip with a transparent background is accepted")
    func transparentProResPasses() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("title.mov")
        try await writeProRes(to: url)

        let result = try await OverlayMediaProbe.validate(url, projectFrame: projectFrame)
        #expect(result.info.hasAlpha)
        #expect(result.info.codec == kCMVideoCodecType_AppleProRes4444)
        #expect(result.info.size == CGSize(width: 160, height: 90))
        #expect(abs(result.info.duration - 1) < 0.01)
        #expect(abs(result.info.frameRate - 10) < 0.5)
        #expect(result.warnings.isEmpty)
    }

    @Test("the same codec with opaque frames is rejected: it would cover the video")
    func opaqueProResRejected() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("opaque.mov")
        try await writeProRes(to: url, transparent: false)

        // Кодек с прозрачностью проходит, отказ даёт сам кадр.
        let message = await rejection(url)
        #expect(message?.hasPrefix("Фон непрозрачный") == true)
        #expect(message?.contains("прозрачным фоном") == true)
    }

    @Test("an H.264 clip has no alpha and is rejected with a hint to render mov")
    func h264Rejected() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("plain.mov")
        try await TestVideoFactory.make(segments: [(duration: 1, loud: false)], to: url)

        let message = await rejection(url)
        #expect(message?.contains("avc1") == true)
        #expect(message?.contains("непрозрачный") == true)
        #expect(message?.contains("--format mov") == true)
    }

    @Test("a webm file and a missing file fail with a next step")
    func webmAndMissingFileRejected() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let webm = directory.appendingPathComponent("title.webm")
        try Data("webm".utf8).write(to: webm)

        let webmMessage = await rejection(webm)
        #expect(webmMessage?.contains("webm") == true)
        #expect(webmMessage?.contains("--format mov") == true)

        let missingMessage = await rejection(directory.appendingPathComponent("gone.mov"))
        #expect(missingMessage?.contains("не найден") == true)
        #expect(missingMessage?.contains("gone.mov") == true)
    }

    @Test("a clip shorter than 0.2 s is rejected")
    func tooShortRejected() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("blink.mov")
        try await writeProRes(to: url, seconds: 0.1)

        let message = await rejection(url)
        #expect(message?.contains("0,2") == true)
    }

    @Test("a square animation on a 16:9 project passes with an aspect warning")
    func aspectMismatchWarns() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("square.mov")
        try await writeProRes(to: url, width: 90, height: 90)

        let result = try await OverlayMediaProbe.validate(url, projectFrame: projectFrame)
        #expect(result.warnings.count == 1)
        #expect(result.warnings.first?.contains("1920×1080") == true)
    }
}
