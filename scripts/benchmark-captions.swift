@preconcurrency import AVFoundation
import AppKit
import CoreVideo
import CryptoKit
import Darwin
import Foundation
import QuartzCore

@testable import MontazhkaKit

/// Run each sample in a fresh process. No models, providers or user projects.
@main
struct CaptionBenchmark {
    struct Options {
        var engine = "current"
        var phase = "init"
        var label = "current"
        var size = CGSize(width: 1920, height: 1080)
        var cueCount = 720
        var seconds = 3600.0
        var fps = 30
        var exportSeconds = 12.0
        var cancellationFraction = 0.25
        var rssLimitMB = 768
        var goldenStart = 0
        var goldenCount = 35
        var drainTransactions = true
        var chunkFrames = 300
        var tinySource = false
        var root = URL(fileURLWithPath: ".build/performance-review", isDirectory: true)

        init(_ arguments: [String]) throws {
            var index = 0
            while index < arguments.count {
                guard index + 1 < arguments.count else {
                    throw CaptionGoldenFixture.Failure(reason: "missing value for \(arguments[index])")
                }
                let value = arguments[index + 1]
                switch arguments[index] {
                case "--engine": engine = value
                case "--phase": phase = value
                case "--label": label = value
                case "--size":
                    guard ["1080p", "4k"].contains(value) else {
                        throw CaptionGoldenFixture.Failure(reason: "size must be 1080p or 4k")
                    }
                    size = value == "4k" ? CGSize(width: 3840, height: 2160) : CGSize(width: 1920, height: 1080)
                case "--cues": cueCount = Int(value) ?? 0
                case "--seconds": seconds = Double(value) ?? 0
                case "--fps": fps = Int(value) ?? 0
                case "--export-seconds": exportSeconds = Double(value) ?? 0
                case "--cancel-fraction": cancellationFraction = Double(value) ?? 0
                case "--rss-limit-mb": rssLimitMB = Int(value) ?? 0
                case "--golden-start": goldenStart = Int(value) ?? -1
                case "--golden-count": goldenCount = Int(value) ?? 0
                case "--drain-transactions":
                    guard ["on", "off"].contains(value) else {
                        throw CaptionGoldenFixture.Failure(reason: "drain transactions must be on or off")
                    }
                    drainTransactions = value == "on"
                case "--chunk-frames": chunkFrames = Int(value) ?? 0
                case "--source-size":
                    guard ["native", "tiny"].contains(value) else {
                        throw CaptionGoldenFixture.Failure(reason: "source size must be native or tiny")
                    }
                    tinySource = value == "tiny"
                case "--root": root = URL(fileURLWithPath: value, isDirectory: true)
                default: throw CaptionGoldenFixture.Failure(reason: "unknown option \(arguments[index])")
                }
                index += 2
            }
            guard ["current", "legacy"].contains(engine), ["init", "sequence", "golden", "export", "fixture", "cancel"].contains(phase),
                cueCount > 0, cueCount <= 5000, seconds > 0, seconds.isFinite,
                fps > 0, fps <= 60, exportSeconds > 0, exportSeconds <= 3600, rssLimitMB > 0,
                cancellationFraction > 0, cancellationFraction < 1,
                goldenStart >= 0, goldenStart < CaptionGoldenFixture.times.count, goldenCount > 0, chunkFrames > 0
            else { throw CaptionGoldenFixture.Failure(reason: "invalid benchmark arguments") }
        }

        var sourceSize: CGSize { tinySource ? CGSize(width: 320, height: 180) : size }
        var sourceURL: URL {
            root.appendingPathComponent(
                "caption-source-\(Int(sourceSize.width))x\(Int(sourceSize.height))-\(exportSeconds)s-\(fps)fps.mov")
        }
    }

    final class Renderer: @unchecked Sendable {
        private let current: OverlayFrameRenderer?
        private let legacy: LegacyCaptionFrameRenderer?

        init(options: Options, cues: [ShortsSubtitleCue], hook: ShortsHook? = nil) throws {
            if options.engine == "legacy" {
                current = nil
                legacy = LegacyCaptionFrameRenderer(
                    renderSize: options.size, cues: cues, appearance: .default, highlight: true, hook: hook)
            } else {
                legacy = nil
                current = OverlayFrameRenderer(
                    renderSize: options.size, cues: cues, appearance: .default, highlight: true, hook: hook)
            }
            guard current != nil || legacy != nil else {
                throw CaptionGoldenFixture.Failure(reason: "renderer unavailable")
            }
        }

        func image(at time: Double) -> CGImage? { current?.image(at: time) ?? legacy?.image(at: time) }
    }

    final class ExportProgress: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private var fraction = 0.0
        func update(_ value: Double) { lock.withLock { fraction = max(fraction, value) } }
        func finish() { lock.withLock { finished = true } }
        var snapshot: (finished: Bool, fraction: Double) { lock.withLock { (finished, fraction) } }
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    static func usage() -> (cpu: Double, peak: Int) {
        var value = rusage()
        getrusage(RUSAGE_SELF, &value)
        let cpu = Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec)
            + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1e6
        return (cpu, Int(value.ru_maxrss))
    }

    static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.resident_size : 0
    }

    static func emit(_ values: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    /// RunLoop APIs are synchronous; keep this helper out of the async body.
    static func drainMainRunLoop() {
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
    }

    static func prepareSource(_ options: Options) async throws {
        guard !FileManager.default.fileExists(atPath: options.sourceURL.path) else { return }
        var generated = AtomicMediaOutput(destinationURL: options.sourceURL)
        defer { generated.discard() }
        try await writeSource(
            to: generated.temporaryURL, size: options.sourceSize, seconds: options.exportSeconds, fps: options.fps)
        try generated.commit()
    }

    @MainActor
    static func main() async throws {
        let options = try Options(Array(CommandLine.arguments.dropFirst()))
        try FileManager.default.createDirectory(at: options.root, withIntermediateDirectories: true)
        let limit = UInt64(options.rssLimitMB) * 1024 * 1024
        let processStarted = ContinuousClock.now
        let progress = ExportProgress()
        let monitor = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "caption-benchmark.rss"))
        monitor.schedule(deadline: .now(), repeating: .milliseconds(50))
        monitor.setEventHandler {
            if residentBytes() > limit {
                try? emit(["status": "rss_limit", "label": options.label, "phase": options.phase,
                    "width": Int(options.size.width), "height": Int(options.size.height),
                    "limitBytes": limit, "residentBytes": residentBytes(),
                    "fraction": progress.snapshot.fraction,
                    "elapsedSeconds": seconds(ContinuousClock.now - processStarted)])
                Darwin.exit(70)
            }
        }
        monitor.resume()
        defer { monitor.cancel() }

        if options.phase == "golden" {
            try golden(options)
            return
        }
        if options.phase == "fixture" {
            let started = ContinuousClock.now
            let cpuStarted = usage().cpu
            let cached = FileManager.default.fileExists(atPath: options.sourceURL.path)
            try await prepareSource(options)
            let elapsed = seconds(ContinuousClock.now - started)
            try emit(["status": "ok", "label": options.label, "phase": options.phase,
                "cached": cached, "sourceWidth": Int(options.sourceSize.width), "sourceHeight": Int(options.sourceSize.height),
                "durationSeconds": options.exportSeconds, "fps": options.fps,
                "sourceFrames": Int((options.exportSeconds * Double(options.fps)).rounded()),
                "fixtureSeconds": elapsed, "fixtureCPUSeconds": usage().cpu - cpuStarted,
                "peakRSSBytes": usage().peak])
            return
        }
        // Fixture generation and metadata loading are outside the timed export.
        if options.phase == "export" || options.phase == "cancel" { try await prepareSource(options) }
        let cues = CaptionGoldenFixture.hourCues(count: options.cueCount, seconds: options.seconds)
        let clock = ContinuousClock()
        let cpuBefore = usage().cpu
        let started = clock.now
        let renderer = try Renderer(options: options, cues: cues)
        let initSeconds = seconds(clock.now - started)
        let residentAfterInit = residentBytes()
        let firstStart = clock.now
        let first = renderer.image(at: 0.1)
        let firstFrameSeconds = seconds(clock.now - firstStart)
        guard first != nil else { throw CaptionGoldenFixture.Failure(reason: "first caption missing") }
        var result: [String: Any] = [
            "status": "ok", "label": options.label, "engine": options.engine, "phase": options.phase,
            "width": Int(options.size.width), "height": Int(options.size.height), "cues": cues.count,
            "wordsPerCue": cues[0].words.count, "timelineSeconds": options.seconds, "fps": options.fps,
            "drainTransactions": options.drainTransactions,
            "chunkFrames": options.chunkFrames,
            "initMilliseconds": initSeconds * 1000, "firstFrameMilliseconds": firstFrameSeconds * 1000,
            "residentBytesAfterInit": residentAfterInit,
        ]
        if options.phase == "sequence" {
            let frameCount = Int((options.seconds * Double(options.fps)).rounded())
            let sequenceStart = clock.now
            let cpuStart = usage().cpu
            var last: CGImage?
            var images = 0
            var repaints = 0
            for frame in 0..<frameCount {
                autoreleasepool {
                    let image = renderer.image(at: Double(frame) / Double(options.fps))
                    if let image {
                        images += 1
                        if image !== last { repaints += 1 }
                    }
                    last = image
                    // A standalone driver has no AppKit RunLoop to drain committed
                    // layer transactions. Use the same drain for both implementations.
                    if options.drainTransactions { CATransaction.flush() }
                }
                if (frame + 1) % options.chunkFrames == 0 {
                    progress.update(Double(frame + 1) / Double(frameCount))
                    await Task.yield()
                    await MainActor.run { drainMainRunLoop() }
                }
                if frame > 0, frame % (options.fps * 300) == 0 {
                    let elapsed = seconds(clock.now - sequenceStart)
                    let text = "\(options.label) \(Int(options.size.width))px: \(frame)/\(frameCount) frames, \(Int(elapsed))s elapsed\n"
                    FileHandle.standardError.write(Data(text.utf8))
                }
            }
            result["sequenceSeconds"] = seconds(clock.now - sequenceStart)
            result["sequenceCPUSeconds"] = usage().cpu - cpuStart
            result["frameRequests"] = frameCount
            result["visibleFrames"] = images
            result["repaintedImages"] = repaints
        }
        if options.phase == "export" || options.phase == "cancel" {
            let output = options.root.appendingPathComponent("caption-export-\(options.label)-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: output) }
            let composition = await CompositionBuilder.build(
                clips: [Clip(sourceURL: options.sourceURL, start: 0, end: options.exportSeconds)]).composition
            let sentinel = Data("Prior benchmark output must survive cancellation.".utf8)
            if options.phase == "cancel" { try sentinel.write(to: output) }
            let exportStart = clock.now
            let cpuStart = usage().cpu
            let exportTask = Task {
                defer { progress.finish() }
                try await Transcoder.export(
                    input: ExportInput(composition: composition, audioMix: nil, overlay: { renderer.image(at: $0) }),
                    settings: Transcoder.Settings(dimensions: options.size, videoBitrate: 8_000_000, audioBitrate: 128_000),
                    to: output, progress: { progress.update($0) })
            }
            var requestedCancellation = false
            while !progress.snapshot.finished {
                if options.phase == "cancel", !requestedCancellation,
                    progress.snapshot.fraction >= options.cancellationFraction
                {
                    requestedCancellation = true
                    exportTask.cancel()
                }
                await Task.yield()
                await MainActor.run { drainMainRunLoop() }
                try await Task.sleep(for: .milliseconds(10))
            }
            do {
                try await exportTask.value
                if options.phase == "cancel" { throw CaptionGoldenFixture.Failure(reason: "export finished before cancellation") }
            } catch is CancellationError {
                guard options.phase == "cancel", requestedCancellation else { throw CancellationError() }
                let preserved = try Data(contentsOf: output) == sentinel
                guard preserved else { throw CaptionGoldenFixture.Failure(reason: "cancellation replaced the prior output") }
                result["cancelled"] = true
                result["requestedCancelFraction"] = options.cancellationFraction
                result["cancelProgress"] = progress.snapshot.fraction
                result["previousOutputPreserved"] = preserved
            }
            let exportSeconds = seconds(clock.now - exportStart)
            result["exportSeconds"] = exportSeconds
            result["exportCPUSeconds"] = usage().cpu - cpuStart
            result["exportDurationSeconds"] = options.exportSeconds
            result["sourceWidth"] = Int(options.sourceSize.width)
            result["sourceHeight"] = Int(options.sourceSize.height)
            result["nativeVideoLoad"] = !options.tinySource
            if options.phase == "export" {
                let times = [0.1, 1, 4.9, 5.3, 10.1, max(0, options.exportSeconds - 0.1)]
                    .map { floor($0 * Double(options.fps)) / Double(options.fps) }
                    .filter { $0 < options.exportSeconds }
                result["exportProbe"] = try await probe(output, times: times)
            }
        }
        result["cpuSeconds"] = usage().cpu - cpuBefore
        result["peakRSSBytes"] = usage().peak
        result["residentBytesAtEnd"] = residentBytes()
        try emit(result)
        withExtendedLifetime(renderer) {}
    }

    static func golden(_ options: Options) throws {
        let hook = ShortsHook(text: "Хук поверх двух фраз", duration: 2)
        let renderer = try Renderer(options: options, cues: CaptionGoldenFixture.overlappingCues, hook: hook)
        guard let reference = LegacyCaptionFrameRenderer(
            renderSize: options.size, cues: CaptionGoldenFixture.overlappingCues, appearance: .default,
            highlight: true, hook: hook)
        else { throw CaptionGoldenFixture.Failure(reason: "reference unavailable") }
        var digest = SHA256()
        let times = Array(CaptionGoldenFixture.times.dropFirst(options.goldenStart).prefix(options.goldenCount))
        for time in times {
            try autoreleasepool {
                let actual = try CaptionGoldenFixture.rgba(renderer.image(at: time))
                let expected = try CaptionGoldenFixture.rgba(reference.image(at: time))
                guard actual == expected else {
                    throw CaptionGoldenFixture.Failure(reason: "golden mismatch at \(time)")
                }
                digest.update(data: Data([actual == nil ? 0 : 1]))
                if let actual { digest.update(data: actual) }
                if options.drainTransactions { CATransaction.flush() }
            }
        }
        try emit(["status": "ok", "label": options.label, "phase": options.phase,
            "width": Int(options.size.width), "height": Int(options.size.height),
            "goldenStart": options.goldenStart, "goldenFrames": times.count,
            "drainTransactions": options.drainTransactions,
            "rgbaDigest": digest.finalize().map { String(format: "%02x", $0) }.joined(),
            "peakRSSBytes": usage().peak])
    }

    static func writeSource(to url: URL, size: CGSize, seconds: Double, fps: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CaptionGoldenFixture.Failure(reason: "source writer start") }
        writer.startSession(atSourceTime: .zero)
        var created: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, nil, &created)
        guard let buffer = created else { throw CaptionGoldenFixture.Failure(reason: "source buffer") }
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<Int(size.height) {
            for x in 0..<Int(size.width) {
                let pixel = base + y * rowBytes + x * 4
                let grey = UInt8(64 + (x / 64 + y / 64) % 96)
                pixel[0] = grey
                pixel[1] = grey
                pixel[2] = grey
                pixel[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let deadline = ContinuousClock.now + .seconds(180)
        for frame in 0..<Int((seconds * Double(fps)).rounded()) {
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, ContinuousClock.now < deadline else {
                    writer.cancelWriting()
                    throw CaptionGoldenFixture.Failure(reason: "source writer stalled")
                }
                try await Task.sleep(for: .milliseconds(2))
            }
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: Int32(fps))) else {
                writer.cancelWriting()
                throw writer.error ?? CaptionGoldenFixture.Failure(reason: "source append")
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: seconds, preferredTimescale: 600))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CaptionGoldenFixture.Failure(reason: "source finish") }
    }

    static func probe(_ url: URL, times: [Double]) async throws -> [String: Any] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CaptionGoldenFixture.Failure(reason: "export has no video")
        }
        let size = try await track.load(.naturalSize)
        let duration = try await asset.load(.duration).seconds
        let packetReader = try AVAssetReader(asset: asset)
        let packets = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        packets.alwaysCopiesSampleData = false
        packetReader.add(packets)
        guard packetReader.startReading() else { throw CaptionGoldenFixture.Failure(reason: "packet probe start") }
        defer { packetReader.cancelReading() }
        var sampleCount = 0
        var timingDigest = SHA256()
        while let sample = packets.copyNextSampleBuffer() {
            sampleCount += CMSampleBufferGetNumSamples(sample)
            let timing = [CMSampleBufferGetPresentationTimeStamp(sample).seconds,
                CMSampleBufferGetDecodeTimeStamp(sample).seconds, CMSampleBufferGetDuration(sample).seconds]
            timing.withUnsafeBytes { timingDigest.update(data: Data($0)) }
        }
        guard packetReader.status == .completed else {
            throw packetReader.error ?? CaptionGoldenFixture.Failure(reason: "packet probe failed")
        }
        var frames: [[String: Any]] = []
        for time in times {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(
                track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            output.alwaysCopiesSampleData = false
            reader.add(output)
            reader.timeRange = CMTimeRange(start: CMTime(seconds: time, preferredTimescale: 600),
                duration: CMTime(value: 1, timescale: 5))
            guard reader.startReading() else { throw CaptionGoldenFixture.Failure(reason: "probe start") }
            defer { reader.cancelReading() }
            guard let sample = output.copyNextSampleBuffer(), let buffer = CMSampleBufferGetImageBuffer(sample) else {
                throw CaptionGoldenFixture.Failure(reason: "probe frame \(time)")
            }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let data = Data(bytes: CVPixelBufferGetBaseAddress(buffer)!,
                count: CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            frames.append(["time": time, "pts": CMSampleBufferGetPresentationTimeStamp(sample).seconds,
                "bgraDigest": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()])
        }
        return ["width": Int(size.width), "height": Int(size.height), "durationSeconds": duration,
            "sampleCount": sampleCount,
            "sampleTimingDigest": timingDigest.finalize().map { String(format: "%02x", $0) }.joined(), "frames": frames]
    }
}
