import Foundation
import AVFoundation

/// Ошибки перекодирования — с человеческим описанием для окна экспорта.
enum TranscodeError: LocalizedError {
    case noVideoTrack
    case readerFailed(Error?)
    case writerFailed(Error?)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: "В проекте нет видеодорожки."
        case .readerFailed(let error): error?.localizedDescription ?? "не удалось прочитать видео"
        case .writerFailed(let error): error?.localizedDescription ?? "не удалось записать файл"
        }
    }
}

/// Перекодирование склейки в MP4 (H.264 + AAC) с заданным битрейтом.
/// В отличие от готовых пресетов AVAssetExportSession даёт точный контроль сжатия,
/// поэтому размер файла предсказуем: (битрейт видео + звука) × длительность.
enum Transcoder {
    struct Settings {
        let dimensions: CGSize
        let videoBitrate: Int
        let audioBitrate: Int
    }

    /// Целевые размеры и битрейт под выбранное качество — по реальному размеру кадра склейки.
    static func settings(for quality: ExportQuality, composition: AVAsset) async throws -> Settings {
        guard let video = try? await composition.loadTracks(withMediaType: .video).first,
              let naturalSize = try? await video.load(.naturalSize),
              let transform = try? await video.load(.preferredTransform)
        else { throw TranscodeError.noVideoTrack }
        let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let display = CGSize(width: abs(rect.width), height: abs(rect.height))
        let dims = quality.targetDimensions(forDisplaySize: display)
        return Settings(dimensions: dims,
                        videoBitrate: quality.videoBitrate(forDimensions: dims),
                        audioBitrate: quality.audioBitrate)
    }

    /// Полное перекодирование: читает склейку (с миксом музыки), кодирует H.264 + AAC.
    /// `progress` зовётся с фоновой очереди значениями 0…1.
    static func export(composition: AVAsset,
                       audioMix: AVAudioMix?,
                       settings: Settings,
                       to url: URL,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        let duration = (try? await composition.load(.duration).seconds) ?? 0
        let videoTracks = (try? await composition.loadTracks(withMediaType: .video)) ?? []
        guard !videoTracks.isEmpty else { throw TranscodeError.noVideoTrack }

        // Пустые звуковые дорожки (без вставленных кусков) ридер не переваривает — отбрасываем.
        var audioTracks: [AVAssetTrack] = []
        for track in (try? await composition.loadTracks(withMediaType: .audio)) ?? [] {
            if let range = try? await track.load(.timeRange), range.duration.seconds > 0 {
                audioTracks.append(track)
            }
        }

        // Видеокомпозиция запекает preferredTransform: вертикальные ролики не заваливаются набок.
        let videoComposition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: composition)

        let reader = try AVAssetReader(asset: composition)
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: videoTracks,
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String:
                                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        )
        videoOutput.videoComposition = videoComposition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw TranscodeError.readerFailed(nil) }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: nil)
            output.audioMix = audioMix
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw TranscodeError.readerFailed(nil) }
            reader.add(output)
            audioOutput = output
        }

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true // moov в начале — стриминг в мессенджерах

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(settings.dimensions.width),
            AVVideoHeightKey: Int(settings.dimensions.height),
            AVVideoScalingModeKey: AVVideoScalingModeResize, // аспект совпадает: цель посчитана от кадра
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: settings.videoBitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalDurationKey: 2.0
            ]
        ])
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw TranscodeError.writerFailed(nil) }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
                AVEncoderBitRateKey: settings.audioBitrate
            ])
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw TranscodeError.writerFailed(nil) }
            writer.add(input)
            audioInput = input
        }

        guard writer.startWriting() else {
            throw TranscodeError.writerFailed(writer.error)
        }
        guard reader.startReading() else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw TranscodeError.readerFailed(reader.error)
        }
        writer.startSession(atSourceTime: .zero)

        // Отмена: сбрасываем ридер — насосы получают nil и сворачиваются сами.
        nonisolated(unsafe) let cancelReader = reader
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await pump(from: videoOutput, to: videoInput, label: "video") { time in
                        guard duration > 0 else { return }
                        progress(min(0.999, time.seconds / duration))
                    }
                }
                if let audioOutput, let audioInput {
                    group.addTask {
                        await pump(from: audioOutput, to: audioInput, label: "audio", onSample: nil)
                    }
                }
            }
        } onCancel: {
            cancelReader.cancelReading()
        }

        if Task.isCancelled {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw CancellationError()
        }
        if reader.status == .failed {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw TranscodeError.readerFailed(reader.error)
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            throw TranscodeError.writerFailed(writer.error)
        }
        progress(1)
    }

    /// Перекачка одного потока ридер → писатель.
    /// ВАЖНО: только requestMediaDataWhenReady — ручной опрос isReadyForMoreMediaData
    /// виснет без живого RunLoop (--selftest). Прогресс — не чаще раза на 0.25 сек видео.
    private static func pump(from outputParam: AVAssetReaderOutput,
                             to inputParam: AVAssetWriterInput,
                             label: String,
                             onSample: (@Sendable (CMTime) -> Void)?) async {
        // Колбэк живёт на своей последовательной очереди — гонок нет, помечаем осознанно
        nonisolated(unsafe) let output = outputParam
        nonisolated(unsafe) let input = inputParam
        let queue = DispatchQueue(label: "montazhka.transcode.\(label)")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var finished = false
            var lastReported = -1.0
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard !finished else { return }
                    guard let sample = output.copyNextSampleBuffer() else {
                        finished = true
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    if let onSample {
                        let time = CMSampleBufferGetPresentationTimeStamp(sample)
                        if time.seconds - lastReported >= 0.25 {
                            lastReported = time.seconds
                            onSample(time)
                        }
                    }
                    if !input.append(sample) {
                        finished = true
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }
    }
}
