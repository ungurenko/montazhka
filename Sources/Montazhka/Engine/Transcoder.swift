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
        case .readerFailed: "Не получилось прочитать исходное видео."
        case .writerFailed: "Не получилось записать готовый файл."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .noVideoTrack: "Добавь хотя бы один клип и попробуй ещё раз."
        case .readerFailed: "Проверь, что исходные файлы на месте и открываются."
        case .writerFailed: "Проверь свободное место на диске и права на папку."
        }
    }

    /// Системная причина — только для лога, в интерфейс она не попадает.
    var underlying: Error? {
        switch self {
        case .noVideoTrack: nil
        case .readerFailed(let error), .writerFailed(let error): error
        }
    }
}

/// Склейка и микс для экспорта. AVFoundation-типы не Sendable, но после сборки
/// композиция нигде больше не мутируется — контейнер осознанно помечен unchecked.
/// `videoComposition` — необязательная замена автоматической (например, кроп 9:16
/// при нарезке на shorts); nil — стандартная сборка из свойств композиции.
/// `overlay` — надписи поверх кадра в момент ленты (вшитые субтитры, хук); nil — без них.
struct ExportInput: @unchecked Sendable {
    let composition: AVAsset
    let audioMix: AVAudioMix?
    var videoComposition: AVVideoComposition?
    var overlay: (@Sendable (Double) -> CGImage?)?

    init(
        composition: AVAsset, audioMix: AVAudioMix?, videoComposition: AVVideoComposition? = nil,
        overlay: (@Sendable (Double) -> CGImage?)? = nil
    ) {
        self.composition = composition
        self.audioMix = audioMix
        self.videoComposition = videoComposition
        self.overlay = overlay
    }
}

/// Входы/выходы насосов перекодирования: оба колбэка живут на общей
/// последовательной очереди вместе с отменой reader.
private struct VideoPumpIO: @unchecked Sendable {
    let videoOutput: AVAssetReaderVideoCompositionOutput
    let videoInput: AVAssetWriterInput
}

private struct AudioPumpIO: @unchecked Sendable {
    let audioOutput: AVAssetReaderAudioMixOutput?
    let audioInput: AVAssetWriterInput?
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
    /// `metadata` пишется в сам MP4 (например, отпечаток проекта).
    /// `progress` зовётся с фоновой очереди значениями 0…1.
    static func export(
        input: ExportInput,
        settings: Settings,
        to url: URL,
        metadata: [AVMetadataItem] = [],
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try Task.checkCancellation()
        var output = AtomicMediaOutput(destinationURL: url)
        defer { output.discard() }
        try await writeTemporary(
            input: input,
            settings: settings,
            to: output.temporaryURL,
            metadata: metadata,
            progress: progress)
        try Task.checkCancellation()
        try output.commit()
    }

    /// Непосредственная запись всегда получает новый временный URL от
    /// `AtomicMediaOutput`; пользовательский файл здесь недоступен.
    static func writeTemporary(
        input: ExportInput,
        settings: Settings,
        to url: URL,
        metadata: [AVMetadataItem],
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
        writer.metadata = metadata

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

        try Task.checkCancellation()
        guard writer.startWriting() else {
            throw TranscodeError.writerFailed(writer.error)
        }
        guard reader.startReading() else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw TranscodeError.readerFailed(reader.error)
        }
        writer.startSession(atSourceTime: .zero)

        // Чтение обеих дорожек и системная отмена reader строго последовательны.
        nonisolated(unsafe) let cancelReader = reader
        let cancellation = MediaReaderPumpQueue(label: "montazhka.transcode") {
            cancelReader.cancelReading()
        }
        nonisolated(unsafe) let observedWriter = writer
        let watchdog = TranscodeWatchdog(cancellation: cancellation) {
            observedWriter.status == .failed || cancelReader.status == .failed
        }
        defer { watchdog.stop() }
        let videoIO = VideoPumpIO(videoOutput: videoOutput, videoInput: videoInput)
        let audioIO = AudioPumpIO(audioOutput: audioOutput, audioInput: audioInput)
        // Надписи кладутся на кадры здесь же, одним проходом: сессия экспорта с Core Animation
        // на macOS 26 сдвигала цвет всего кадра (серый 128 → 145).
        var burnOverlay: (@Sendable (CMSampleBuffer) -> CMSampleBuffer)?
        let burner = input.overlay.map(FrameOverlayBurner.init(overlay:))
        if let burner { burnOverlay = { sample in burner.burn(sample) } }
        let transform = burnOverlay
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await pump(
                        from: videoIO.videoOutput, to: videoIO.videoInput, cancellation: cancellation,
                        watchdog: watchdog,
                        transform: transform
                    ) { time in
                        guard duration > 0 else { return }
                        progress(min(0.999, time.seconds / duration))
                    }
                }
                if let audioOutput = audioIO.audioOutput, let audioInput = audioIO.audioInput {
                    group.addTask {
                        await pump(
                            from: audioOutput, to: audioInput, cancellation: cancellation, watchdog: watchdog,
                            onSample: nil)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }

        if Task.isCancelled {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw CancellationError()
        }
        if writer.status == .failed || watchdog.timedOut {
            writer.cancelWriting()
            throw TranscodeError.writerFailed(writer.error)
        }
        if reader.status == .failed || reader.status == .cancelled {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw TranscodeError.readerFailed(reader.error)
        }
        // Файл без надписей, которые должны были быть, — не готовый файл.
        if burner?.didFail == true {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw TranscodeError.writerFailed(nil)
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            throw TranscodeError.writerFailed(writer.error)
        }
        progress(1)
    }

    /// Потоки ридер → писатель. Колбэк requestMediaDataWhenReady зовётся строго
    /// последовательно на общей очереди reader — бокс хранит состояние дорожки.
    private final class PumpState: @unchecked Sendable {
        var finished = false
        var lastReported = -1.0
        var cancellationHandler: UUID?
    }

    /// Перекачка одного потока ридер → писатель.
    /// ВАЖНО: только requestMediaDataWhenReady — ручной опрос isReadyForMoreMediaData
    /// виснет без живого RunLoop (--selftest). Прогресс — не чаще раза на 0.25 сек видео.
    /// `transform` меняет кадр перед записью (надписи); nil — кадр идёт как есть.
    private static func pump(
        from outputParam: AVAssetReaderOutput,
        to inputParam: AVAssetWriterInput,
        cancellation: MediaReaderPumpQueue, watchdog: TranscodeWatchdog,
        transform: (@Sendable (CMSampleBuffer) -> CMSampleBuffer)? = nil,
        onSample: (@Sendable (CMTime) -> Void)?
    ) async {
        // Колбэк и завершение по отмене живут на общей очереди reader.
        nonisolated(unsafe) let output = outputParam
        nonisolated(unsafe) let input = inputParam
        let queue = cancellation.queue
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                let state = PumpState()
                let finish: @Sendable () -> Void = {
                    guard !state.finished else { return }
                    state.finished = true
                    cancellation.removeHandler(state.cancellationHandler)
                    input.markAsFinished()
                    continuation.resume()
                }
                state.cancellationHandler = cancellation.onCancel(finish)
                guard !state.finished else { return }
                if cancellation.isCancelled {
                    cancellation.stopOnQueue()
                    return finish()
                }
                input.requestMediaDataWhenReady(on: queue) {
                    while input.isReadyForMoreMediaData {
                        guard !state.finished else { return }
                        if cancellation.isCancelled {
                            cancellation.stopOnQueue()
                            return finish()
                        }
                        guard let sample = output.copyNextSampleBuffer() else { return finish() }
                        if cancellation.isCancelled {
                            cancellation.stopOnQueue()
                            return finish()
                        }
                        if let onSample {
                            let time = CMSampleBufferGetPresentationTimeStamp(sample)
                            if time.seconds - state.lastReported >= 0.25 {
                                state.lastReported = time.seconds
                                onSample(time)
                            }
                        }
                        guard input.append(transform?(sample) ?? sample) else {
                            cancellation.stopOnQueue()
                            return finish()
                        }
                        watchdog.advanced()
                    }
                }
            }
        }
    }
}
