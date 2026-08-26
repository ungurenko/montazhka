@preconcurrency import AVFoundation
import CoreVideo
import Foundation

/// Генерирует настоящий видеофайл (чёрные кадры + звук «речь/тишина») для тестов движка.
enum TestVideoFactory {
    /// Участки звука: (длительность сек, громко ли).
    static func make(
        segments: [(duration: Double, loud: Bool)],
        videoLuma: UInt8 = 0,
        to url: URL
    ) async throws {
        try await make(
            segments: segments.map { ($0.duration, $0.loud ? 0.4 : 0.0) },
            videoLuma: videoLuma,
            to: url)
    }

    /// Участки звука с точной громкостью: (длительность сек, амплитуда синуса 0…1).
    /// `toneFrequency` — частота синуса в Гц (по умолчанию 220, «голосовая»).
    static func make(
        segments: [(duration: Double, amplitude: Double)],
        toneFrequency: Double = 220,
        videoLuma: UInt8 = 0,
        to url: URL
    ) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        // Видео: 320x180, 10 к/с, чёрные кадры
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 320,
                AVVideoHeightKey: 180,
            ])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 320,
                kCVPixelBufferHeightKey as String: 180,
            ]
        )
        writer.add(videoInput)

        // Звук: несжатый PCM 16 бит 16 кГц моно
        let sampleRate = 16000.0
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var formatDesc: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &asbd,
            layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &formatDesc)
        let audioInput = AVAssetWriterInput(
            mediaType: .audio, outputSettings: nil,
            sourceFormatHint: formatDesc)
        audioInput.expectsMediaDataInRealTime = false
        writer.add(audioInput)

        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "test", code: 1) }
        writer.startSession(atSourceTime: .zero)

        let totalDuration = segments.reduce(0) { $0 + $1.duration }

        // Один однотонный кадр — используем для всех моментов времени
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixelBuffer)
        guard let frame = pixelBuffer else { throw NSError(domain: "test", code: 2) }
        CVPixelBufferLockBaseAddress(frame, [])
        if let base = CVPixelBufferGetBaseAddress(frame) {
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            let count = CVPixelBufferGetDataSize(frame)
            for offset in stride(from: 0, to: count, by: 4) {
                bytes[offset] = videoLuma
                bytes[offset + 1] = videoLuma
                bytes[offset + 2] = videoLuma
                bytes[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(frame, [])

        // Звук одним куском: синус заданной частоты и амплитуды («речь» громче, «шум» тише)
        var samples: [Int16] = []
        for segment in segments {
            let count = Int(segment.duration * sampleRate)
            for i in 0..<count {
                let value = sin(2.0 * .pi * toneFrequency * Double(i) / sampleRate) * segment.amplitude
                samples.append(Int16(value * 32767))
            }
        }
        let audioSample = try makeAudioSampleBuffer(samples: samples, formatDesc: formatDesc!)

        // ВАЖНО: писатель чередует видео и звук — кормить оба потока надо ПАРАЛЛЕЛЬНО,
        // иначе он ждёт второй поток и всё замирает.
        let videoIO = VideoFeedIO(input: videoInput, adaptor: adaptor, frame: frame, writer: writer)
        let audioIO = AudioFeedIO(input: audioInput, sample: audioSample)
        async let videoDone: Void = feedVideo(io: videoIO, totalDuration: totalDuration)
        async let audioDone: Void = feedAudio(io: audioIO)
        _ = await (videoDone, audioDone)

        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? NSError(domain: "test", code: 5) }
    }

    /// Входы видео-насоса: колбэк живёт на своей последовательной очереди, гонок нет.
    private struct VideoFeedIO: @unchecked Sendable {
        let input: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let frame: CVPixelBuffer
        let writer: AVAssetWriter
    }

    /// Входы звукового насоса — по той же схеме.
    private struct AudioFeedIO: @unchecked Sendable {
        let input: AVAssetWriterInput
        let sample: CMSampleBuffer
    }

    /// Рабочее состояние колбэка насоса — менять можно только с его очереди.
    private final class FeedState: @unchecked Sendable {
        var frameTime = 0.0
        var finished = false
    }

    private static func feedVideo(io: VideoFeedIO, totalDuration: Double) async {
        let queue = DispatchQueue(label: "selftest.video")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let state = FeedState()
            io.input.requestMediaDataWhenReady(on: queue) {
                while io.input.isReadyForMoreMediaData {
                    if state.frameTime >= totalDuration || io.writer.status != .writing {
                        guard !state.finished else { return }
                        state.finished = true
                        io.input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    io.adaptor.append(
                        io.frame,
                        withPresentationTime: CMTime(
                            seconds: state.frameTime,
                            preferredTimescale: 600))
                    state.frameTime += 0.1
                }
            }
        }
    }

    private static func feedAudio(io: AudioFeedIO) async {
        let queue = DispatchQueue(label: "selftest.audio")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let state = FeedState()
            io.input.requestMediaDataWhenReady(on: queue) {
                guard io.input.isReadyForMoreMediaData, !state.finished else { return }
                state.finished = true
                io.input.append(io.sample)
                io.input.markAsFinished()
                continuation.resume()
            }
        }
    }

    private static func makeAudioSampleBuffer(
        samples: [Int16],
        formatDesc: CMAudioFormatDescription
    ) throws -> CMSampleBuffer {
        let dataLength = samples.count * 2
        var blockBuffer: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil,
            blockLength: dataLength, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0,
            dataLength: dataLength, flags: 0,
            blockBufferOut: &blockBuffer)
        guard let block = blockBuffer else { throw NSError(domain: "test", code: 3) }
        _ = samples.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!, blockBuffer: block,
                offsetIntoDestination: 0, dataLength: dataLength)
        }
        var sampleBuffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: formatDesc,
            sampleCount: samples.count,
            presentationTimeStamp: .zero,
            packetDescriptions: nil, sampleBufferOut: &sampleBuffer
        )
        guard let result = sampleBuffer else { throw NSError(domain: "test", code: 4) }
        return result
    }
}
