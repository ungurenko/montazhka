@preconcurrency import AVFoundation
import Foundation

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

/// Склейка и микс для экспорта. AVFoundation-типы не Sendable, но после сборки
/// композиция нигде больше не мутируется — контейнер осознанно помечен unchecked.
/// `videoComposition` — необязательная замена автоматической (например, кроп 9:16
/// при нарезке на shorts); nil — стандартная сборка из свойств композиции.
struct ExportInput: @unchecked Sendable {
    let composition: AVAsset
    let audioMix: AVAudioMix?
    var videoComposition: AVVideoComposition?

    init(composition: AVAsset, audioMix: AVAudioMix?, videoComposition: AVVideoComposition? = nil) {
        self.composition = composition
        self.audioMix = audioMix
        self.videoComposition = videoComposition
    }
}

/// Входы/выходы насосов перекодирования: колбэк каждого живёт на своей
/// последовательной очереди, гонок между потоками нет.
private struct VideoPumpIO: @unchecked Sendable {
    let videoOutput: AVAssetReaderVideoCompositionOutput
    let videoInput: AVAssetWriterInput
}

private struct AudioPumpIO: @unchecked Sendable {
    let audioOutput: AVAssetReaderAudioMixOutput?
    let audioInput: AVAssetWriterInput?
}

private final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession

    init(_ session: AVAssetExportSession) {
        self.session = session
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
    static func settings(for quality: ExportQuality, input: ExportInput) async throws -> Settings {
        guard let video = try? await input.composition.loadTracks(withMediaType: .video).first,
            let naturalSize = try? await video.load(.naturalSize),
            let transform = try? await video.load(.preferredTransform)
        else { throw TranscodeError.noVideoTrack }
        let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let display = CGSize(width: abs(rect.width), height: abs(rect.height))
        let dims = quality.targetDimensions(forDisplaySize: display)
        return Settings(
            dimensions: dims,
            videoBitrate: quality.videoBitrate(forDimensions: dims),
            audioBitrate: quality.audioBitrate)
    }

    /// Полное перекодирование: читает склейку (с миксом музыки), кодирует H.264 + AAC.
    /// `progress` зовётся с фоновой очереди значениями 0…1.
    static func export(
        input: ExportInput,
        settings: Settings,
        to url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        var output = AtomicMediaOutput(destinationURL: url)
        defer { output.discard() }
        try await exportDirect(
            input: input,
            settings: settings,
            to: output.temporaryURL,
            progress: progress)
        try Task.checkCancellation()
        try output.commit()
    }

    /// Непосредственная запись всегда получает новый временный URL от
    /// `AtomicMediaOutput`; пользовательский файл здесь недоступен.
    private static func exportDirect(
        input: ExportInput,
        settings: Settings,
        to url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let composition = input.composition
        let audioMix = input.audioMix
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
        // Для нарезки на shorts сюда может приходить композиция с кропом 9:16.
        let videoComposition: AVVideoComposition
        if let custom = input.videoComposition {
            videoComposition = custom
        } else {
            videoComposition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: composition)
        }

        let reader = try AVAssetReader(asset: composition)
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: videoTracks,
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ]
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

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true  // moov в начале — стриминг в мессенджерах

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(settings.dimensions.width),
                AVVideoHeightKey: Int(settings.dimensions.height),
                AVVideoScalingModeKey: AVVideoScalingModeResize,  // аспект совпадает: цель посчитана от кадра
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: settings.videoBitrate,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoMaxKeyFrameIntervalDurationKey: 2.0,
                ],
            ])
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw TranscodeError.writerFailed(nil) }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48000,
                    AVNumberOfChannelsKey: 2,
                    AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
                    AVEncoderBitRateKey: settings.audioBitrate,
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
        let videoIO = VideoPumpIO(videoOutput: videoOutput, videoInput: videoInput)
        let audioIO = AudioPumpIO(audioOutput: audioOutput, audioInput: audioInput)
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await pump(from: videoIO.videoOutput, to: videoIO.videoInput, label: "video") { time in
                        guard duration > 0 else { return }
                        progress(min(0.999, time.seconds / duration))
                    }
                }
                if let audioOutput = audioIO.audioOutput, let audioInput = audioIO.audioInput {
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

    /// Core Animation tool поддерживается AVFoundation в offline-экспорте через
    /// AVAssetExportSession. После запекания субтитров вторым проходом возвращаем
    /// привычные битрейт и размеры, которыми пользуется основной Transcoder.
    static func exportWithOfflineComposition(
        input: ExportInput,
        settings: Settings,
        to url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard input.videoComposition?.animationTool != nil else {
            try await export(input: input, settings: settings, to: url, progress: progress)
            return
        }

        let intermediate = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-subtitles-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: intermediate) }

        try await exportWithSession(
            input: input,
            to: intermediate,
            progress: { progress($0 * 0.5) })

        try await export(
            input: ExportInput(composition: AVURLAsset(url: intermediate), audioMix: nil),
            settings: settings,
            to: url,
            progress: { progress(0.5 + $0 * 0.5) })
    }

    private static func exportWithSession(
        input: ExportInput,
        to url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let videoComposition = input.videoComposition,
            let session = AVAssetExportSession(
                asset: input.composition,
                presetName: AVAssetExportPresetHighestQuality)
        else {
            throw TranscodeError.writerFailed(nil)
        }

        let box = ExportSessionBox(session)
        session.videoComposition = videoComposition
        session.audioMix = input.audioMix
        session.outputURL = url
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        try? FileManager.default.removeItem(at: url)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let monitor = Task.detached { [box] in
                    while !Task.isCancelled {
                        progress(Double(box.session.progress))
                        switch box.session.status {
                        case .completed, .failed, .cancelled:
                            return
                        default:
                            try? await Task.sleep(nanoseconds: 200_000_000)
                        }
                    }
                }

                box.session.exportAsynchronously {
                    monitor.cancel()
                    progress(1)
                    switch box.session.status {
                    case .completed:
                        continuation.resume()
                    case .cancelled:
                        continuation.resume(throwing: CancellationError())
                    default:
                        continuation.resume(
                            throwing: TranscodeError.writerFailed(box.session.error))
                    }
                }
            }
        } onCancel: {
            box.session.cancelExport()
        }
    }

    /// Потоки ридер → писатель. Колбэк requestMediaDataWhenReady зовётся строго
    /// последовательно на своей очереди — бокс хранит его рабочее состояние.
    private final class PumpState: @unchecked Sendable {
        var finished = false
        var lastReported = -1.0
    }

    /// Перекачка одного потока ридер → писатель.
    /// ВАЖНО: только requestMediaDataWhenReady — ручной опрос isReadyForMoreMediaData
    /// виснет без живого RunLoop (--selftest). Прогресс — не чаще раза на 0.25 сек видео.
    private static func pump(
        from outputParam: AVAssetReaderOutput,
        to inputParam: AVAssetWriterInput,
        label: String,
        onSample: (@Sendable (CMTime) -> Void)?
    ) async {
        // Колбэк живёт на своей последовательной очереди — гонок нет, помечаем осознанно
        nonisolated(unsafe) let output = outputParam
        nonisolated(unsafe) let input = inputParam
        let queue = DispatchQueue(label: "montazhka.transcode.\(label)")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let state = PumpState()
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard !state.finished else { return }
                    guard let sample = output.copyNextSampleBuffer() else {
                        state.finished = true
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    if let onSample {
                        let time = CMSampleBufferGetPresentationTimeStamp(sample)
                        if time.seconds - state.lastReported >= 0.25 {
                            state.lastReported = time.seconds
                            onSample(time)
                        }
                    }
                    if !input.append(sample) {
                        state.finished = true
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }
    }
}
