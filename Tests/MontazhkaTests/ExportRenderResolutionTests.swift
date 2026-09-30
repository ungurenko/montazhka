@preconcurrency import AVFoundation
import CoreGraphics
import CoreVideo
import CryptoKit
import Foundation
import VideoToolbox

@testable import MontazhkaKit

#if !EXPORT_RESOLUTION_BENCHMARK
    import Testing

    @Suite("Export render resolution", .serialized)
    struct ExportRenderResolutionTests {
        @Test("the inactive rollout policy sends every normal export through the nil quality path")
        func inactivePolicyKeepsTheDefaultPath() {
            for quality in ExportQuality.allCases {
                #expect(ExportRenderResolutionPolicy.requestedQuality(quality) == nil)
            }
        }

        @Test(
            "nil/default stay legacy and target plans preserve native API geometry, cadence and colour",
            arguments: ExportResolutionFixture.cases)
        func plansKeepTheirContract(_ item: ExportResolutionFixture.Case) async throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("montazhka-resolution-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try await ExportResolutionFixture.prepare(at: root, colours: [item.colour], sourceFPS: 2)
            let scene = ExportResolutionFixture.scene(item, root: root)
            var defaultRequest = MediaRenderRequest(project: scene.project, mode: .export, readyEnhancedAudio: [:])
            defaultRequest.subtitleLayer = scene.subtitles
            let defaultPlan = await scene.pipeline.render(defaultRequest)
            let native = try await ExportResolutionFixture.render(scene, quality: nil)
            let target = try await ExportResolutionFixture.render(scene, quality: item.quality)
            let preview = try await ExportResolutionFixture.render(scene, mode: .preview, quality: item.quality)
            #expect(defaultPlan.warnings.isEmpty)
            let issues = try await ExportResolutionFixture.planIssues(
                item, scene: scene, native: native, candidate: target, preview: preview, oracle: .targetAPI)
            #expect(issues.isEmpty, "\(item.id): \(issues.joined(separator: "; "))")
            #expect(defaultPlan.videoPlan?.frameComposition.renderSize == native.videoPlan?.frameComposition.renderSize)
            #expect(
                defaultPlan.videoPlan?.frameComposition.frameDuration
                    == native.videoPlan?.frameComposition.frameDuration)
            let legacyReference = try await ExportResolutionFixture.frameComposition(native)
            for result in [defaultPlan, preview] {
                let observed = try await ExportResolutionFixture.frameComposition(result)
                #expect(observed.renderSize == legacyReference.renderSize)
                #expect(observed.frameDuration == legacyReference.frameDuration)
                #expect(observed.colorPrimaries == legacyReference.colorPrimaries)
                #expect(observed.colorTransferFunction == legacyReference.colorTransferFunction)
                #expect(observed.colorYCbCrMatrix == legacyReference.colorYCbCrMatrix)
                let placementIssues = try await ExportResolutionFixture.geometryIssues(
                    result, original: legacyReference, resized: observed)
                #expect(placementIssues.isEmpty)
            }
            if scene.subtitles != nil {
                let first = try #require(defaultPlan.videoPlan?.overlayImageAt?(1))
                let second = try #require(native.videoPlan?.overlayImageAt?(1))
                let previewImage = try #require(preview.videoPlan?.overlayImageAt?(1))
                #expect(first.width == Int(item.displaySize.width) && first.height == Int(item.displaySize.height))
                #expect(first.dataProvider?.data == second.dataProvider?.data)
                #expect(first.dataProvider?.data == previewImage.dataProvider?.data)
            }
        }

        @Test("an explicit target only changes the render canvas and preserves cadence and colour")
        func directCompositionTarget() async throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("montazhka-resolution-direct-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try await ExportResolutionFixture.prepare(at: root, colours: [.sdr], sourceFPS: 2)
            let item = ExportResolutionFixture.Case(scene: .animation, colour: .sdr, quality: .medium)
            let scene = ExportResolutionFixture.scene(item, root: root)
            let visible = OverlayTimeline.resolve(scene.project.overlays, clips: scene.project.clips)
                .filter { $0.status == .visible }
            let built = await CompositionBuilder.buildResult(clips: scene.project.clips, overlays: visible)
            let native = try #require(
                try await ProjectVideoComposition.make(
                    composition: built.composition, baseTrackID: built.baseVideoTrackID,
                    overlays: built.overlayTracks, subtitles: nil, targetRenderSize: nil))
            let target = try #require(
                try await ProjectVideoComposition.make(
                    composition: built.composition, baseTrackID: built.baseVideoTrackID,
                    overlays: built.overlayTracks, subtitles: nil, targetRenderSize: item.outputSize))
            #expect(native.frameComposition.renderSize == ExportResolutionFixture.nativeSize)
            #expect(target.frameComposition.renderSize == item.outputSize)
            #expect(target.frameComposition.frameDuration == native.frameComposition.frameDuration)
            #expect(target.frameComposition.colorPrimaries == native.frameComposition.colorPrimaries)
            #expect(target.frameComposition.colorTransferFunction == native.frameComposition.colorTransferFunction)
            #expect(target.frameComposition.colorYCbCrMatrix == native.frameComposition.colorYCbCrMatrix)
        }
    }
#endif

/// The same local fixtures and comparison rules serve the tests and standalone benchmark.
/// A failed or inconclusive comparison keeps the target-size optimisation disabled.
enum ExportResolutionFixture {
    enum SceneKind: String, CaseIterable, Sendable {
        case plain, rotated, mixed, animation, subtitles, freeze
    }

    enum Colour: String, CaseIterable, Sendable {
        case sdr, hlg
    }

    enum PlanOracle: Equatable, Sendable {
        case legacyAcceptance
        case targetAPI
    }

    struct Case: Sendable, CustomStringConvertible {
        let scene: SceneKind
        let colour: Colour
        let quality: ExportQuality

        var id: String { "\(scene.rawValue)-\(colour.rawValue)-\(quality.rawValue)" }
        var description: String { id }
        var displaySize: CGSize {
            scene == .rotated
                ? CGSize(width: nativeSize.height, height: nativeSize.width) : nativeSize
        }
        var outputSize: CGSize { quality.targetDimensions(forDisplaySize: displaySize) }
        var duration: Double { sourceSeconds + (scene == .freeze ? 0.5 : 0) }
    }

    struct Scene: Sendable {
        let project: Project
        let subtitles: ProjectSubtitleLayer?
        let root: URL

        var pipeline: MediaPipeline {
            MediaPipeline(
                voiceStore: VoiceEnhanceStore(cacheDir: root.appendingPathComponent("voice")),
                musicEQStore: MusicEQStore(cacheDir: root.appendingPathComponent("eq")))
        }
    }

    struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    struct PixelDifference: Codable, Sendable {
        let meanAbsolute: Double
        let rootMeanSquare: Double
        let maximum: Int

        func fits(_ baseline: PixelDifference) -> Bool {
            meanAbsolute <= baseline.meanAbsolute + 1e-9
                && rootMeanSquare <= baseline.rootMeanSquare + 1e-9
                && maximum <= baseline.maximum
        }
    }

    struct FileInfo: Codable, Sendable {
        let width: Int
        let height: Int
        let duration: Double
        let frameTimes: [Double]
        let colourTags: [String: String]
        let audioDigest: String
    }

    struct Report: Codable, Sendable {
        let caseID: String
        let compatible: Bool
        let issues: [String]
        let baselineRepeat: PixelDifference
        let candidateDifference: PixelDifference
        let baseline: FileInfo
        let candidate: FileInfo
    }

    static let nativeSize = CGSize(width: 3840, height: 2160)
    static let sourceSeconds = 1.5
    static let fps: Int32 = 30
    static let cases: [Case] = SceneKind.allCases.flatMap { scene in
        Colour.allCases.flatMap { colour in
            [ExportQuality.medium, .compact].map { Case(scene: scene, colour: colour, quality: $0) }
        }
    }

    static func prepare(
        at root: URL, colours: [Colour] = Colour.allCases, sourceFPS: Int32 = fps
    ) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = root.appendingPathComponent("audio.mov")
        if !FileManager.default.fileExists(atPath: audio.path) {
            try await TestVideoFactory.make(
                segments: [(duration: sourceSeconds, amplitude: 0.1)], toneFrequency: 660, to: audio)
        }
        let overlay = root.appendingPathComponent("overlay.mov")
        if !FileManager.default.fileExists(atPath: overlay.path) {
            try await TestOverlayFactory.make(width: 1280, height: 720, duration: 0.7, fps: fps, to: overlay)
        }
        for colour in colours {
            for rotated in [false, true] {
                let output = source(colour, rotated: rotated, root: root)
                if FileManager.default.fileExists(atPath: output.path) {
                    try await validateSource(output, colour: colour, rotated: rotated, sourceFPS: sourceFPS)
                    continue
                }
                let temporary = root.appendingPathComponent("video-\(colour.rawValue)-\(rotated).mov")
                defer { try? FileManager.default.removeItem(at: temporary) }
                let frame = try sourceFrame(colour)
                let primaries = colour == .hlg ? AVVideoColorPrimaries_ITU_R_2020 : AVVideoColorPrimaries_ITU_R_709_2
                let transfer =
                    colour == .hlg ? AVVideoTransferFunction_ITU_R_2100_HLG : AVVideoTransferFunction_ITU_R_709_2
                let matrix = colour == .hlg ? AVVideoYCbCrMatrix_ITU_R_2020 : AVVideoYCbCrMatrix_ITU_R_709_2
                var settings: [String: Any] = [
                    AVVideoCodecKey: colour == .hlg ? AVVideoCodecType.hevc : .h264,
                    AVVideoWidthKey: Int(nativeSize.width), AVVideoHeightKey: Int(nativeSize.height),
                    AVVideoColorPropertiesKey: [
                        AVVideoColorPrimariesKey: primaries,
                        AVVideoTransferFunctionKey: transfer, AVVideoYCbCrMatrixKey: matrix,
                    ],
                ]
                if colour == .hlg {
                    // AVVideoColorPropertiesKey already opts into wide colour.
                    // The allow-wide key is unnecessary for this writer input.
                    settings[AVVideoCompressionPropertiesKey] = [
                        AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String
                    ]
                }
                let transform = rotated ? CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0) : .identity
                try await TestOverlayFactory.writeStill(
                    frame, settings: settings, fileType: .mov, frameCount: Int(sourceSeconds * Double(sourceFPS)),
                    frameDuration: CMTime(value: 1, timescale: sourceFPS), transform: transform, to: temporary)
                try await mux(video: temporary, audio: audio, transform: transform, to: output)
                try await validateSource(output, colour: colour, rotated: rotated, sourceFPS: sourceFPS)
            }
        }
    }

    private static func validateSource(
        _ url: URL, colour: Colour, rotated: Bool, sourceFPS: Int32
    ) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first,
            !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
        else { throw Failure(reason: "\(url.lastPathComponent): fixture tracks are missing.") }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let oriented = CGRect(origin: .zero, size: size).applying(transform)
        let expected = rotated ? CGSize(width: nativeSize.height, height: nativeSize.width) : nativeSize
        let sourceRate = try await track.load(.nominalFrameRate)
        let duration = try await asset.load(.duration).seconds
        guard size == nativeSize, abs(abs(oriented.width) - expected.width) < 0.001,
            abs(abs(oriented.height) - expected.height) < 0.001,
            abs(sourceRate - Float(sourceFPS)) < 0.001, abs(duration - sourceSeconds) < 0.001
        else { throw Failure(reason: "\(url.lastPathComponent): fixture geometry, cadence or duration is invalid.") }
        let tags = try await colourTags(asset)
        let expectedTags = [
            kCVImageBufferColorPrimariesKey as String:
                colour == .hlg ? AVVideoColorPrimaries_ITU_R_2020 : AVVideoColorPrimaries_ITU_R_709_2,
            kCVImageBufferTransferFunctionKey as String:
                colour == .hlg ? AVVideoTransferFunction_ITU_R_2100_HLG : AVVideoTransferFunction_ITU_R_709_2,
            kCVImageBufferYCbCrMatrixKey as String:
                colour == .hlg ? AVVideoYCbCrMatrix_ITU_R_2020 : AVVideoYCbCrMatrix_ITU_R_709_2,
        ]
        guard tags == expectedTags else {
            throw Failure(reason: "\(url.lastPathComponent): fixture colour metadata is invalid: \(tags)")
        }
    }

    static func source(_ colour: Colour, rotated: Bool = false, root: URL) -> URL {
        root.appendingPathComponent("source-\(colour.rawValue)-\(rotated ? "portrait" : "landscape").mov")
    }

    static func scene(_ item: Case, root: URL) -> Scene {
        let base = MediaReference(url: source(item.colour, rotated: item.scene == .rotated, root: root))
        var clips = [Clip(source: base, start: 0, end: sourceSeconds)]
        if item.scene == .mixed {
            let portrait = MediaReference(url: source(item.colour, rotated: true, root: root))
            clips = [
                Clip(source: base, start: 0, end: sourceSeconds / 2),
                Clip(source: portrait, start: 0, end: sourceSeconds / 2),
            ]
        }
        var project = Project(name: "Resolution \(item.id)", clips: clips)
        project.voiceEnhance.enabled = false
        project.music.enabled = false
        project.export.freezeTailSeconds = item.scene == .freeze ? 0.5 : 0
        if item.scene == .animation || item.scene == .freeze {
            project.overlays = [
                ProjectOverlay(
                    id: UUID(), media: MediaReference(url: root.appendingPathComponent("overlay.mov")),
                    anchor: OverlayAnchor(
                        sourceID: base.id, sourceTime: item.scene == .freeze ? 1.05 : 0.45, wordText: "fixture"),
                    align: .start, payoffAt: 0, duration: 0.7, position: .bottomRight, scale: 0.4)
            ]
        }
        let subtitles: ProjectSubtitleLayer?
        if item.scene == .subtitles || item.scene == .freeze {
            let cue = ShortsSubtitleCue(
                words: [
                    ShortsSubtitleWord(text: "Проверяем", start: 0.25, end: 0.6),
                    ShortsSubtitleWord(text: "качество", start: 0.6, end: 1.0),
                    ShortsSubtitleWord(text: "кадра", start: 1.0, end: sourceSeconds),
                ], start: 0.25, end: sourceSeconds)
            subtitles = ProjectSubtitleLayer(cues: [cue], appearance: .default, highlight: true)
        } else {
            subtitles = nil
        }
        return Scene(project: project, subtitles: subtitles, root: root)
    }

    static func render(_ scene: Scene, mode: MediaRenderMode = .export, quality: ExportQuality?) async throws
        -> MediaRenderResult
    {
        var request = MediaRenderRequest(project: scene.project, mode: mode, readyEnhancedAudio: [:])
        request.subtitleLayer = scene.subtitles
        request.exportQuality = quality
        let result = await scene.pipeline.render(request)
        guard result.warnings.isEmpty else {
            throw Failure(reason: "Rendering warnings: \(result.warnings.map(\.message))")
        }
        return result
    }

    static func export(_ rendered: MediaRenderResult, item: Case, to output: URL) async throws {
        let job = FinalExportJob(
            input: ExportInput(
                composition: rendered.composition, audioMix: rendered.audioMix,
                videoComposition: rendered.videoPlan?.frameComposition, overlay: rendered.videoPlan?.overlayImageAt),
            quality: item.quality, sizing: .quality(item.quality),
            subtitleCues: nil, subtitlesSkippedReason: nil, normalizeLoudness: false, projectFingerprint: nil)
        _ = try await FinalExport.run(job, to: output, progress: { _ in })
    }

    static func verify(_ item: Case, root: URL) async throws -> Report {
        let scene = scene(item, root: root)
        let outputs = root.appendingPathComponent(item.id, isDirectory: true)
        try FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: true)
        let baselineURL = outputs.appendingPathComponent("native.mp4")
        let repeatURL = outputs.appendingPathComponent("native-repeat.mp4")
        let candidateURL = outputs.appendingPathComponent("target.mp4")
        let baseline = try await render(scene, quality: nil)
        let repeatBaseline = try await render(scene, quality: nil)
        let candidate = try await render(scene, quality: item.quality)
        let preview = try await render(scene, mode: .preview, quality: item.quality)
        var issues = try await planIssues(item, scene: scene, native: baseline, candidate: candidate, preview: preview)
        try await export(baseline, item: item, to: baselineURL)
        try await export(repeatBaseline, item: item, to: repeatURL)
        try await export(candidate, item: item, to: candidateURL)
        let originalInfo = try await inspect(baselineURL)
        let repeatInfo = try await inspect(repeatURL)
        let candidateInfo = try await inspect(candidateURL)
        if !sameStructure(originalInfo, repeatInfo) {
            issues.append("Baseline exports are not structurally repeatable.")
        }
        if !sameStructure(originalInfo, candidateInfo) {
            issues.append("Duration, frame timestamps, colour metadata or decoded audio changed.")
        }
        if originalInfo.width != Int(item.outputSize.width) || originalInfo.height != Int(item.outputSize.height)
            || abs(originalInfo.duration - item.duration) > 1.0 / Double(fps) + 0.002
        {
            issues.append("Baseline output geometry or duration does not match the fixture.")
        }
        let repeatability = try await difference(baselineURL, repeatURL)
        let candidateDifference = try await difference(baselineURL, candidateURL)
        if !candidateDifference.fits(repeatability) {
            issues.append("Decoded RGB differs by more than the measured baseline-repeat tolerance.")
        }
        return Report(
            caseID: item.id, compatible: issues.isEmpty, issues: issues, baselineRepeat: repeatability,
            candidateDifference: candidateDifference, baseline: originalInfo, candidate: candidateInfo)
    }

    static func planIssues(
        _ item: Case, scene: Scene, native: MediaRenderResult, candidate: MediaRenderResult, preview: MediaRenderResult,
        oracle: PlanOracle = .legacyAcceptance
    ) async throws -> [String] {
        var issues: [String] = []
        let original = try await frameComposition(native)
        guard let resized = candidate.videoPlan else {
            throw Failure(reason: "\(item.id): requested target composition is missing.")
        }
        if (item.scene == .plain || item.scene == .rotated)
            && (native.videoPlan != nil || preview.videoPlan != nil)
        {
            issues.append("A nil/default or preview plain project acquired a custom video plan.")
        }
        if oracle == .legacyAcceptance, original.renderSize != item.displaySize {
            issues.append("The legacy automatic canvas differs from the target API's oriented native canvas.")
        }
        if resized.frameComposition.renderSize != item.outputSize {
            issues.append("The candidate does not render at the requested output size.")
        }
        if let previewPlan = preview.videoPlan, previewPlan.frameComposition.renderSize != item.displaySize {
            issues.append("Export quality changed preview resolution.")
        }
        if resized.frameComposition.frameDuration != original.frameDuration {
            issues.append("Render frame cadence changed.")
        }
        if resized.frameComposition.colorPrimaries != original.colorPrimaries
            || resized.frameComposition.colorTransferFunction != original.colorTransferFunction
            || resized.frameComposition.colorYCbCrMatrix != original.colorYCbCrMatrix
        {
            issues.append("Composition colour properties changed.")
        }
        if scene.subtitles != nil {
            guard let originalImage = native.videoPlan?.overlayImageAt?(1),
                let previewImage = preview.videoPlan?.overlayImageAt?(1), let targetImage = resized.overlayImageAt?(1)
            else { throw Failure(reason: "\(item.id): burned subtitle picture is missing.") }
            if originalImage.width != Int(item.displaySize.width)
                || originalImage.height != Int(item.displaySize.height)
                || previewImage.width != originalImage.width || previewImage.height != originalImage.height
                || targetImage.width != originalImage.width || targetImage.height != originalImage.height
                || originalImage.dataProvider?.data != previewImage.dataProvider?.data
                || originalImage.dataProvider?.data != targetImage.dataProvider?.data
            {
                issues.append("Native subtitle layout changed in the default, preview or target path.")
            }
        }
        var geometryReference: AVVideoComposition = original
        if oracle == .targetAPI, native.videoPlan == nil {
            // The rotated automatic legacy plan retains the raw track canvas.
            // This oracle checks the target API against its explicit oriented
            // native canvas. Acceptance still compares actual legacy framing.
            guard let track = try await native.composition.loadTracks(withMediaType: .video).first,
                let explicitNative = try await ProjectVideoComposition.make(
                    composition: native.composition, baseTrackID: track.trackID, overlays: [], subtitles: nil,
                    targetRenderSize: item.displaySize)
            else { throw Failure(reason: "The explicit native-size target API reference is missing.") }
            geometryReference = explicitNative.frameComposition
        }
        issues.append(
            contentsOf: try await geometryIssues(
                native, original: geometryReference, resized: resized.frameComposition))
        return issues
    }

    static func frameComposition(_ result: MediaRenderResult) async throws -> AVMutableVideoComposition {
        if let plan = result.videoPlan { return plan.frameComposition }
        // This is exactly the nil videoComposition branch of Transcoder.
        return try await AVMutableVideoComposition.videoComposition(withPropertiesOf: result.composition)
    }

    static func inspect(_ url: URL) async throws -> FileInfo {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw Failure(reason: "\(url.lastPathComponent): no video.")
        }
        let size = try await track.load(.naturalSize)
        // Compressed output includes zero-sample codec-control buffers with
        // invalid PTS. Measure the same decoded pictures used for RGB comparison.
        let (reader, output) = try await frameReader(url)
        defer { reader.cancelReading() }
        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard CMSampleBufferGetImageBuffer(sample) != nil, timestamp.isFinite else {
                throw Failure(reason: "A decoded frame has missing image data or an invalid timestamp.")
            }
            times.append(timestamp)
        }
        guard reader.status == .completed else {
            throw reader.error ?? Failure(reason: "Frame timestamp read stopped early.")
        }
        return FileInfo(
            width: Int(size.width), height: Int(size.height), duration: try await asset.load(.duration).seconds,
            frameTimes: times.sorted(), colourTags: try await colourTags(asset),
            audioDigest: try await audioDigest(asset))
    }

    static func sameStructure(_ before: FileInfo, _ after: FileInfo) -> Bool {
        let tick = 1.0 / 600 + 0.0001
        return before.width == after.width && before.height == after.height
            && abs(before.duration - after.duration) <= tick
            && before.colourTags == after.colourTags && before.audioDigest == after.audioDigest
            && before.frameTimes.count == after.frameTimes.count
            && zip(before.frameTimes, after.frameTimes).allSatisfy { abs($0 - $1) <= tick }
    }

    static func geometryIssues(
        _ native: MediaRenderResult, original: AVVideoComposition, resized: AVVideoComposition
    ) async throws -> [String] {
        guard let nativeInstruction = original.instructions.first as? AVVideoCompositionInstruction,
            let targetInstruction = resized.instructions.first as? AVVideoCompositionInstruction
        else { throw Failure(reason: "Video instructions are missing.") }
        guard nativeInstruction.layerInstructions.count == targetInstruction.layerInstructions.count else {
            return ["The number of composited video layers changed."]
        }
        for (before, after) in zip(nativeInstruction.layerInstructions, targetInstruction.layerInstructions) {
            guard let track = try await native.composition.loadTrack(withTrackID: before.trackID) else {
                throw Failure(reason: "A native layer lost its track.")
            }
            let size = try await track.load(.naturalSize)
            for seconds in [0.0, 0.5, 0.9, 1.25] {
                let time = CMTime(seconds: seconds, preferredTimescale: 600)
                let a = CGRect(origin: .zero, size: size).applying(try layerTransform(before, at: time))
                let b = CGRect(origin: .zero, size: size).applying(try layerTransform(after, at: time))
                let pairs = [
                    (a.minX / original.renderSize.width, b.minX / resized.renderSize.width),
                    (a.minY / original.renderSize.height, b.minY / resized.renderSize.height),
                    (a.width / original.renderSize.width, b.width / resized.renderSize.width),
                    (a.height / original.renderSize.height, b.height / resized.renderSize.height),
                ]
                if pairs.contains(where: { abs($0.0 - $0.1) > 1e-6 }) {
                    return ["Normalised placement of a base or animation layer changed."]
                }
            }
        }
        return []
    }

    private static func layerTransform(_ layer: AVVideoCompositionLayerInstruction, at time: CMTime) throws
        -> CGAffineTransform
    {
        var start = CGAffineTransform.identity
        var end = CGAffineTransform.identity
        var range = CMTimeRange.zero
        guard layer.getTransformRamp(for: time, start: &start, end: &end, timeRange: &range) else {
            throw Failure(reason: "A video layer has no transform at \(time.seconds) s.")
        }
        return start
    }

    private static func colourTags(_ asset: AVAsset) async throws -> [String: String] {
        guard let track = try await asset.loadTracks(withMediaType: .video).first,
            let format = try await track.load(.formatDescriptions).first
        else { throw Failure(reason: "Video format description is missing.") }
        let tags = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
        let keys = [
            kCVImageBufferColorPrimariesKey as String, kCVImageBufferTransferFunctionKey as String,
            kCVImageBufferYCbCrMatrixKey as String,
        ]
        return Dictionary(
            uniqueKeysWithValues: keys.compactMap { key in
                (tags[key] as? String).map { (key, $0) }
            })
    }

    private static func audioDigest(_ asset: AVAsset) async throws -> String {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw Failure(reason: "The audio fixture disappeared from the export.")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
                AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? Failure(reason: "Audio decode failed.") }
        defer { reader.cancelReading() }
        var hash = SHA256()
        var total = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else {
                throw Failure(reason: "Decoded audio has no contiguous PCM data.")
            }
            var data = Data(count: CMBlockBufferGetDataLength(block))
            let status = data.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            guard status == noErr else { throw Failure(reason: "Decoded audio copy failed.") }
            total += data.count
            hash.update(data: data)
        }
        guard reader.status == .completed, total > 0 else {
            throw reader.error ?? Failure(reason: "Decoded audio read stopped early.")
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func difference(_ before: URL, _ after: URL) async throws -> PixelDifference {
        let first = try await frameReader(before)
        let second = try await frameReader(after)
        defer { first.reader.cancelReading(); second.reader.cancelReading() }
        var absolute = 0.0
        var squared = 0.0
        var count = 0
        var maximum = 0
        while let sample = first.output.copyNextSampleBuffer() {
            guard let other = second.output.copyNextSampleBuffer(),
                let a = CMSampleBufferGetImageBuffer(sample), let b = CMSampleBufferGetImageBuffer(other),
                CVPixelBufferGetWidth(a) == CVPixelBufferGetWidth(b),
                CVPixelBufferGetHeight(a) == CVPixelBufferGetHeight(b)
            else { throw Failure(reason: "Decoded frame geometry or count differs.") }
            guard
                abs(
                    CMSampleBufferGetPresentationTimeStamp(sample).seconds
                        - CMSampleBufferGetPresentationTimeStamp(other).seconds) <= 1.0 / 600 + 0.0001
            else { throw Failure(reason: "Decoded frame timestamps differ.") }
            CVPixelBufferLockBaseAddress(a, .readOnly)
            CVPixelBufferLockBaseAddress(b, .readOnly)
            defer {
                CVPixelBufferUnlockBaseAddress(a, .readOnly)
                CVPixelBufferUnlockBaseAddress(b, .readOnly)
            }
            guard let aBase = CVPixelBufferGetBaseAddress(a), let bBase = CVPixelBufferGetBaseAddress(b) else {
                throw Failure(reason: "Decoded frame memory is missing.")
            }
            let width = CVPixelBufferGetWidth(a)
            let height = CVPixelBufferGetHeight(a)
            for y in 0..<height {
                let ar = (aBase + y * CVPixelBufferGetBytesPerRow(a)).assumingMemoryBound(to: UInt8.self)
                let br = (bBase + y * CVPixelBufferGetBytesPerRow(b)).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width {
                    for channel in 0..<3 {
                        let delta = abs(Int(ar[x * 4 + channel]) - Int(br[x * 4 + channel]))
                        absolute += Double(delta)
                        squared += Double(delta * delta)
                        maximum = max(maximum, delta)
                        count += 1
                    }
                }
            }
        }
        guard second.output.copyNextSampleBuffer() == nil, first.reader.status == .completed,
            second.reader.status == .completed, count > 0
        else { throw Failure(reason: "Decoded frame read stopped early.") }
        return PixelDifference(
            meanAbsolute: absolute / Double(count), rootMeanSquare: sqrt(squared / Double(count)), maximum: maximum)
    }

    private static func frameReader(_ url: URL) async throws
        -> (reader: AVAssetReader, output: AVAssetReaderTrackOutput)
    {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw Failure(reason: "Decoded file has no video.")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? Failure(reason: "Frame decode failed.") }
        return (reader, output)
    }

    private static func sourceFrame(_ colour: Colour) throws -> CVPixelBuffer {
        let width = Int(nativeSize.width), height = Int(nativeSize.height)
        let buffer = try TestOverlayFactory.pixelBuffer(
            width: width, height: height,
            format: colour == .hlg ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        if colour == .hlg {
            guard let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
                let uvBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)
            else { throw Failure(reason: "10-bit HLG frame planes are missing.") }
            for y in 0..<height {
                let row = (yBase + y * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)).assumingMemoryBound(
                    to: UInt16.self)
                for x in 0..<width {
                    let value = x < width / 8 && y < height / 8 ? 940 : 64 + (876 * x / (width - 1))
                    row[x] = UInt16(value) << 6
                }
            }
            for y in 0..<height / 2 {
                let row = (uvBase + y * CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)).assumingMemoryBound(
                    to: UInt16.self)
                for x in 0..<width { row[x] = 512 << 6 }
            }
            CVBufferSetAttachment(
                buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
            CVBufferSetAttachment(
                buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                .shouldPropagate)
            CVBufferSetAttachment(
                buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        } else {
            guard let base = CVPixelBufferGetBaseAddress(buffer) else {
                throw Failure(reason: "SDR frame memory is missing.")
            }
            for y in 0..<height {
                let row = (base + y * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width {
                    let marked = x < width / 8 && y < height / 8
                    row[x * 4] = marked ? 255 : UInt8(48 + ((x / 32 + y / 32).isMultiple(of: 2) ? 96 : 0))
                    row[x * 4 + 1] = marked ? 255 : UInt8(32 + 192 * y / (height - 1))
                    row[x * 4 + 2] = marked ? 255 : UInt8(32 + 192 * x / (width - 1))
                    row[x * 4 + 3] = 255
                }
            }
        }
        return buffer
    }

    private static func mux(video: URL, audio: URL, transform: CGAffineTransform, to output: URL) async throws {
        let videoAsset = AVURLAsset(url: video)
        let audioAsset = AVURLAsset(url: audio)
        guard let v = try await videoAsset.loadTracks(withMediaType: .video).first,
            let a = try await audioAsset.loadTracks(withMediaType: .audio).first
        else { throw Failure(reason: "Fixture mux inputs are missing.") }
        let composition = AVMutableComposition()
        guard
            let videoTrack = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
            let audioTrack = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw Failure(reason: "Fixture mux tracks could not be created.") }
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: sourceSeconds, preferredTimescale: 600))
        try videoTrack.insertTimeRange(range, of: v, at: .zero)
        videoTrack.preferredTransform = transform
        try audioTrack.insertTimeRange(range, of: a, at: .zero)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw Failure(reason: "Fixture passthrough mux is unavailable.")
        }
        try await session.export(to: output, as: .mov)
    }
}
