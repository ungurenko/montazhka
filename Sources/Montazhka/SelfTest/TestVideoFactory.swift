import Foundation
import AVFoundation
import CoreVideo

/// Генерирует настоящий видеофайл (чёрные кадры + звук «речь/тишина») для тестов движка.
enum TestVideoFactory {
    /// Участки звука: (длительность сек, громко ли).
    static func make(segments: [(duration: Double, loud: Bool)], to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        // Видео: 320x180, 10 к/с, чёрные кадры
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 320,
            AVVideoHeightKey: 180
        ])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 320,
                kCVPixelBufferHeightKey as String: 180
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
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd,
                                       layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil,
                                       extensions: nil, formatDescriptionOut: &formatDesc)
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil,
                                            sourceFormatHint: formatDesc)
        audioInput.expectsMediaDataInRealTime = false
        writer.add(audioInput)

        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "test", code: 1) }
        writer.startSession(atSourceTime: .zero)

        let totalDuration = segments.reduce(0) { $0 + $1.duration }

        // Один чёрный кадр — используем для всех моментов времени
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixelBuffer)
        guard let frame = pixelBuffer else { throw NSError(domain: "test", code: 2) }
        CVPixelBufferLockBaseAddress(frame, [])
        memset(CVPixelBufferGetBaseAddress(frame), 0, CVPixelBufferGetDataSize(frame))
        CVPixelBufferUnlockBaseAddress(frame, [])

        // Звук одним куском: синус 220 Гц для «речи», ноль для тишины
        var samples: [Int16] = []
        for segment in segments {
            let count = Int(segment.duration * sampleRate)
            for i in 0..<count {
                if segment.loud {
                    let value = sin(2.0 * .pi * 220.0 * Double(i) / sampleRate) * 0.4
                    samples.append(Int16(value * 32767))
                } else {
                    samples.append(0)
                }
            }
        }
        let audioSample = try makeAudioSampleBuffer(samples: samples, formatDesc: formatDesc!)

        // ВАЖНО: писатель чередует видео и звук — кормить оба потока надо ПАРАЛЛЕЛЬНО,
        // иначе он ждёт второй поток и всё замирает.
        async let videoDone: Void = feedVideo(input: videoInput, adaptor: adaptor,
                                              frame: frame, totalDuration: totalDuration,
                                              writer: writer)
        async let audioDone: Void = feedAudio(input: audioInput, sample: audioSample)
        _ = await (videoDone, audioDone)

        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? NSError(domain: "test", code: 5) }
    }

    private static func feedVideo(input inputParam: AVAssetWriterInput,
                                  adaptor adaptorParam: AVAssetWriterInputPixelBufferAdaptor,
                                  frame frameParam: CVPixelBuffer,
                                  totalDuration: Double,
                                  writer writerParam: AVAssetWriter) async {
        // Колбэк живёт на последовательной очереди — гонок нет, помечаем осознанно
        nonisolated(unsafe) let input = inputParam
        nonisolated(unsafe) let adaptor = adaptorParam
        nonisolated(unsafe) let frame = frameParam
        nonisolated(unsafe) let writer = writerParam
        let queue = DispatchQueue(label: "selftest.video")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var frameTime = 0.0
            var finished = false
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    if frameTime >= totalDuration || writer.status != .writing {
                        guard !finished else { return }
                        finished = true
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    adaptor.append(frame, withPresentationTime: CMTime(seconds: frameTime, preferredTimescale: 600))
                    frameTime += 0.1
                }
            }
        }
    }

    private static func feedAudio(input inputParam: AVAssetWriterInput, sample sampleParam: CMSampleBuffer) async {
        nonisolated(unsafe) let input = inputParam
        nonisolated(unsafe) let sample = sampleParam
        let queue = DispatchQueue(label: "selftest.audio")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var finished = false
            input.requestMediaDataWhenReady(on: queue) {
                guard input.isReadyForMoreMediaData, !finished else { return }
                finished = true
                input.append(sample)
                input.markAsFinished()
                continuation.resume()
            }
        }
    }

    private static func makeAudioSampleBuffer(samples: [Int16],
                                              formatDesc: CMAudioFormatDescription) throws -> CMSampleBuffer {
        let dataLength = samples.count * 2
        var blockBuffer: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil,
                                           blockLength: dataLength, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0,
                                           dataLength: dataLength, flags: 0,
                                           blockBufferOut: &blockBuffer)
        guard let block = blockBuffer else { throw NSError(domain: "test", code: 3) }
        _ = samples.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
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
