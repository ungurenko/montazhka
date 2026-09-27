@preconcurrency import AVFoundation
import CoreVideo
import Foundation
import Testing

@testable import MontazhkaKit

/// ВРЕМЕННО, только для разбора красного CI на macOS 26: цветовые пометки и пиксели
/// на каждом шаге вшивания субтитров и в нескольких вариантах цветовой политики.
/// Строки с префиксом COLORDIAG читаются из лога CI. Файл удаляется после разбора.
@Suite("Color diagnostics")
struct ColorDiagnosticsTests {
    private static let width = 320
    private static let height = 180

    private func log(_ line: String) {
        print("COLORDIAG \(line)")
    }

    @Test("colour at every step of the burned-subtitles chain")
    func burnedChain() async throws {
        log("os \(ProcessInfo.processInfo.operatingSystemVersionString)")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-colordiag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("base.mov")
        try await TestVideoFactory.make(segments: [(duration: 3, loud: true)], videoLuma: 128, to: video)
        let overlayURL = root.appendingPathComponent("overlay.mov")
        try await TestOverlayFactory.make(width: Self.width, height: Self.height, duration: 1, to: overlayURL)
        let base = MediaReference(url: video)
        var project = Project(name: "diag", clips: [Clip(source: base, start: 0, end: 3)])
        project.overlays = [
            ProjectOverlay(
                id: UUID(), media: MediaReference(url: overlayURL),
                anchor: OverlayAnchor(sourceID: base.id, sourceTime: 1, wordText: nil),
                align: .start, payoffAt: 0, duration: 1, position: .full, scale: 1)
        ]
        let cue = ShortsSubtitleCue(
            words: [ShortsSubtitleWord(text: "Привет", start: 0.2, end: 0.5)], start: 0.2, end: 0.5)
        let layer = ProjectSubtitleLayer(
            cues: [cue], appearance: ShortsSubtitleSettings.saved().appearance, highlight: false)
        let pipeline = MediaPipeline(
            voiceStore: VoiceEnhanceStore(cacheDir: root.appendingPathComponent("voice")),
            musicEQStore: MusicEQStore(cacheDir: root.appendingPathComponent("eq")))
        let result = await pipeline.render(
            MediaRenderRequest(project: project, mode: .export, readyEnhancedAudio: [:], subtitleLayer: layer))
        let plan = try #require(result.videoPlan)

        await describe("base", video)
        await describe("overlay", overlayURL)
        describe("frameComposition", plan.frameComposition)
        describe("exportComposition", plan.exportComposition)
        await pixels("composited") { try await compositedFrame(result.composition, plan.frameComposition, at: $0) }

        // Цепочка до исправления: сессия экспорта с цветом композиции как есть, затем Transcoder.
        await chain("app", result: result, videoComposition: plan.exportComposition, root: root)
        // Как после исправления: цвет композиции для сессии закреплён.
        await chain(
            "fixed", result: result, videoComposition: Transcoder.sessionComposition(plan.exportComposition),
            root: root)

        for (name, primaries, transfer, matrix) in [
            (
                "force709", AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrix_ITU_R_709_2
            ),
            (
                "force601", AVVideoColorPrimaries_SMPTE_C, AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrix_ITU_R_601_4
            ),
        ] {
            guard let forced = plan.exportComposition.mutableCopy() as? AVMutableVideoComposition else { continue }
            forced.colorPrimaries = primaries
            forced.colorTransferFunction = transfer
            forced.colorYCbCrMatrix = matrix
            await chain(name, result: result, videoComposition: forced, root: root)
        }

        // Без субтитров — путь зелёного теста анимаций.
        do {
            let plain = root.appendingPathComponent("plain.mp4")
            let input = ExportInput(
                composition: result.composition, audioMix: result.audioMix, videoComposition: plan.frameComposition)
            let settings = try await Transcoder.settings(
                for: .compact, input: ExportInput(composition: result.composition, audioMix: nil))
            try await Transcoder.export(input: input, settings: settings, to: plain, progress: { _ in })
            await describe("plain", plain)
            await pixels("plain") { try await decodedFrame(plain, at: $0) }
        } catch {
            log("plain failed \(error)")
        }
    }

    /// Сессия экспорта с этой видеокомпозицией, затем второй проход Transcoder.
    private func chain(
        _ name: String, result: MediaRenderResult, videoComposition: AVVideoComposition, root: URL
    ) async {
        do {
            let intermediate = root.appendingPathComponent("\(name)-intermediate.mp4")
            try await session(result, videoComposition: videoComposition, to: intermediate)
            await describe("\(name)-intermediate", intermediate)
            await pixels("\(name)-intermediate") { try await decodedFrame(intermediate, at: $0) }
            let asset = AVURLAsset(url: intermediate)
            let pass2 = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
            describe("\(name)-pass2Composition", pass2)
            await pixels("\(name)-pass2read") { try await compositedFrame(asset, pass2, at: $0) }
            let final = root.appendingPathComponent("\(name)-final.mp4")
            let input = ExportInput(composition: asset, audioMix: nil)
            let settings = try await Transcoder.settings(for: .compact, input: input)
            try await Transcoder.export(input: input, settings: settings, to: final, progress: { _ in })
            await describe("\(name)-final", final)
            await pixels("\(name)-final") { try await decodedFrame(final, at: $0) }
        } catch {
            log("\(name) failed \(error)")
        }
    }

    private final class SessionBox: @unchecked Sendable {
        let session: AVAssetExportSession
        init(_ session: AVAssetExportSession) { self.session = session }
    }

    private func session(
        _ result: MediaRenderResult, videoComposition: AVVideoComposition, to url: URL
    ) async throws {
        let session = try #require(
            AVAssetExportSession(asset: result.composition, presetName: AVAssetExportPresetHighestQuality))
        session.videoComposition = videoComposition
        session.audioMix = result.audioMix
        session.outputURL = url
        session.outputFileType = .mp4
        let box = SessionBox(session)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            box.session.exportAsynchronously { continuation.resume() }
        }
        if box.session.status != .completed {
            throw box.session.error ?? CocoaError(.fileWriteUnknown)
        }
    }

    private func describe(_ label: String, _ url: URL) async {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
            let descriptions = try? await track.load(.formatDescriptions),
            let format = descriptions.first
        else {
            log("\(label) tags: unreadable")
            return
        }
        let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
        let codec = CMFormatDescriptionGetMediaSubType(format)
        let fourCC =
            String(
                bytes: [24, 16, 8, 0].map { UInt8((codec >> $0) & 0xFF) }, encoding: .ascii) ?? "?"
        let dims = CMVideoFormatDescriptionGetDimensions(format)
        func value(_ key: CFString) -> String { extensions[key as String].map { "\($0)" } ?? "nil" }
        log(
            "\(label) tags: codec=\(fourCC) \(dims.width)x\(dims.height)"
                + " primaries=\(value(kCMFormatDescriptionExtension_ColorPrimaries))"
                + " transfer=\(value(kCMFormatDescriptionExtension_TransferFunction))"
                + " matrix=\(value(kCMFormatDescriptionExtension_YCbCrMatrix))"
                + " fullRange=\(value(kCMFormatDescriptionExtension_FullRangeVideo))"
                + " gamma=\(value(kCMFormatDescriptionExtension_GammaLevel))")
    }

    private func describe(_ label: String, _ composition: AVVideoComposition) {
        log(
            "\(label) colour: primaries=\(composition.colorPrimaries ?? "nil")"
                + " transfer=\(composition.colorTransferFunction ?? "nil")"
                + " matrix=\(composition.colorYCbCrMatrix ?? "nil")"
                + " size=\(composition.renderSize) animationTool=\(composition.animationTool != nil)")
    }

    private func pixels(_ label: String, _ frame: (Double) async throws -> CVPixelBuffer) async {
        let points = TestOverlayFactory.probes(width: Self.width, height: Self.height)
        for time in [0.8, 1.5, 2.5] {
            do {
                let buffer = try await frame(time)
                let attachments = CVBufferCopyAttachments(buffer, .shouldPropagate) as? [String: Any] ?? [:]
                let matrix = attachments[kCVImageBufferYCbCrMatrixKey as String].map { "\($0)" } ?? "nil"
                let transfer = attachments[kCVImageBufferTransferFunctionKey as String].map { "\($0)" } ?? "nil"
                let primaries = attachments[kCVImageBufferColorPrimariesKey as String].map { "\($0)" } ?? "nil"
                log(
                    "\(label) t=\(time) centre=\(pixel(buffer, points.centre)) band=\(pixel(buffer, points.band))"
                        + " corner=\(pixel(buffer, points.corner)) top=\(pixel(buffer, CGPoint(x: 20, y: 20)))"
                        + " buffer=[\(primaries) \(transfer) \(matrix)]")
            } catch {
                log("\(label) t=\(time) failed \(error)")
            }
        }
    }

    private struct ReadFailure: Error {
        let reason: String
    }

    private func compositedFrame(
        _ asset: AVAsset, _ videoComposition: AVVideoComposition, at seconds: Double
    ) async throws -> CVPixelBuffer {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: try await asset.loadTracks(withMediaType: .video),
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = videoComposition
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ReadFailure(reason: "composition read") }
        defer { reader.cancelReading() }
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetPresentationTimeStamp(sample).seconds >= seconds - 0.001 else { continue }
            return try #require(CMSampleBufferGetImageBuffer(sample))
        }
        throw ReadFailure(reason: "no frame at \(seconds) s")
    }

    private func decodedFrame(_ url: URL, at seconds: Double) async throws -> CVPixelBuffer {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: seconds, preferredTimescale: 600), duration: CMTime(value: 1, timescale: 10))
        guard reader.startReading() else { throw reader.error ?? ReadFailure(reason: "file read") }
        defer { reader.cancelReading() }
        let sample = try #require(output.copyNextSampleBuffer())
        return try #require(CMSampleBufferGetImageBuffer(sample))
    }

    private func pixel(_ buffer: CVPixelBuffer, _ point: CGPoint) -> String {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return "?" }
        let at = base + Int(point.y) * CVPixelBufferGetBytesPerRow(buffer) + Int(point.x) * 4
        return "(\(at[2]),\(at[1]),\(at[0]))"
    }
}
