@preconcurrency import AVFoundation
import Accelerate
import CoreMedia
import CoreVideo
import Foundation
import OSLog
import VideoToolbox

/// Готовит файл анимации к наложению — один раз, когда его добавляют в проект.
///
/// Стандартный компоновщик AVFoundation считает пиксели наложения premultiplied
/// и не смотрит на пометку StraightAlpha. HyperFrames же пишет ProRes 4444 с прямой
/// (straight) альфой и без цветовых пометок, а цвет кодирует по BT.601. Без подготовки
/// красный выходит (255,25,0), а белая полоса с альфой 0,5 — чисто белой.
///
/// Как читается цвет: декодер отдаёт кадры в родном YCbCr с альфой (y416). Матрицу
/// перевода в RGB выбираем сами — из описания дорожки, а без пометки BT.601 (так кодирует
/// ffmpeg) — и перезаписываем ею догадку декодера на каждом кадре: для кадров от 720 px
/// в ширину он угадывает BT.709. VTPixelTransferSession берёт матрицу из вложений буфера
/// и переводит кадр в BGRA. Диапазон (limited/full) задаёт сам формат y416 — его соблюдает
/// декодер. Первичные цвета и гамму не пересчитываем: копия помечается BT.709.
///
/// Копия — ProRes 4444, цвет умножен на альфу (если ещё не был), пометки
/// PremultipliedAlpha и BT.709, тот же размер и те же времена кадров, без звука.
enum OverlayMediaNormalizer {
    /// Сколько ждать следующего кадра, прежде чем признать запись зависшей.
    private static let stallLimit: DispatchTimeInterval = .seconds(30)
    private static let renderHint = "отрендерьте её заново (HyperFrames с --format mov)"

    /// Что нужно знать о дорожке исходника до чтения кадров.
    private struct SourceVideo {
        let track: AVAssetTrack
        let width: Int
        let height: Int
        let transform: CGAffineTransform
        let timeRange: CMTimeRange
        let timeScale: CMTimeScale
        let matrix: CFString
        let isPremultiplied: Bool
    }

    /// `source` уже проверен `OverlayMediaProbe`. Пишет копию во временный файл рядом
    /// с `destination` и переносит на место только целиком; при ошибке и отмене файлов не остаётся.
    /// Остановить можно двумя путями: отменить задачу Swift, которая ждёт вызов, или вернуть
    /// true из `isCancelled`. Флаг спрашивают на каждом кадре с фоновой очереди, где
    /// `Task.isCancelled` всегда false, — отмену задачи насос ловит сам.
    static func normalize(
        _ source: URL, to destination: URL, isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async throws {
        let name = source.lastPathComponent
        let asset = AVURLAsset(url: source)
        let video = try await loadVideo(of: asset, name: name)
        var output = AtomicMediaOutput(destinationURL: destination)
        defer { output.discard() }
        try await transcode(video, of: asset, name: name, to: output.temporaryURL, isCancelled: isCancelled)
        guard !isCancelled() else { throw CancellationError() }
        try Task.checkCancellation()
        do {
            try output.commit()
        } catch {
            Logger.export.error(
                "Overlay copy was not moved into place: \(error.localizedDescription, privacy: .public)")
            throw writeFailed
        }
    }

    private static func loadVideo(of asset: AVURLAsset, name: String) async throws -> SourceVideo {
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw unreadable(name)
            }
            let (size, transform, timeRange, timeScale, formats) = try await track.load(
                .naturalSize, .preferredTransform, .timeRange, .naturalTimeScale, .formatDescriptions)
            guard let format = formats.first, size.width >= 1, size.height >= 1 else { throw unreadable(name) }
            let tags = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
            let alphaMode = tags[kCVImageBufferAlphaChannelModeKey as String] as? String
            let matrix = tags[kCVImageBufferYCbCrMatrixKey as String] as? String
            return SourceVideo(
                track: track, width: Int(size.width.rounded()), height: Int(size.height.rounded()),
                transform: transform, timeRange: timeRange, timeScale: timeScale,
                matrix: matrix.map { $0 as CFString } ?? kCVImageBufferYCbCrMatrix_ITU_R_601_4,
                isPremultiplied: alphaMode == (kCVImageBufferAlphaChannelMode_PremultipliedAlpha as String))
        } catch let error as AgentServiceError {
            throw error
        } catch {
            Logger.export.error("Overlay track did not load: \(error.localizedDescription, privacy: .public)")
            throw unreadable(name)
        }
    }

    private static func transcode(
        _ video: SourceVideo, of asset: AVAsset, name: String, to url: URL,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws {
        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: asset)
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            Logger.export.error("Overlay reader/writer failed: \(error.localizedDescription, privacy: .public)")
            throw unreadable(name)
        }
        let output = AVAssetReaderTrackOutput(
            track: video.track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_4444AYpCbCr16])
        guard reader.canAdd(output) else { throw unreadable(name) }
        reader.add(output)

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings(for: video))
        input.expectsMediaDataInRealTime = false
        input.transform = video.transform
        if video.timeScale > 0 { input.mediaTimeScale = video.timeScale }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: video.width, kCVPixelBufferHeightKey as String: video.height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ])
        guard writer.canAdd(input) else { throw writeFailed }
        writer.add(input)

        guard writer.startWriting() else {
            Logger.export.error("Overlay writer did not start: \(String(describing: writer.error), privacy: .public)")
            throw writeFailed
        }
        guard reader.startReading() else {
            writer.cancelWriting()
            Logger.export.error("Overlay reader did not start: \(String(describing: reader.error), privacy: .public)")
            throw unreadable(name)
        }
        writer.startSession(atSourceTime: .zero)

        let outcome: PumpOutcome
        if let pool = adaptor.pixelBufferPool, let converter = FrameConverter(video: video, pool: pool) {
            let pump = Pump(
                reader: reader, output: output, input: input, adaptor: adaptor, converter: converter,
                isCancelled: isCancelled)
            outcome = await withTaskCancellationHandler {
                await pump.run(stallLimit: stallLimit)
            } onCancel: {
                pump.cancel()
            }
        } else {
            outcome = .failed(writeFailed)
        }

        switch outcome {
        case .completed:
            writer.endSession(atSourceTime: video.timeRange.end)
            await writer.finishWriting()
            guard writer.status == .completed else {
                Logger.export.error("Overlay writer failed: \(String(describing: writer.error), privacy: .public)")
                throw writeFailed
            }
        case .cancelled:
            reader.cancelReading()
            writer.cancelWriting()
            throw CancellationError()
        case .readFailed:
            Logger.export.error("Overlay reader failed: \(String(describing: reader.error), privacy: .public)")
            reader.cancelReading()
            writer.cancelWriting()
            throw unreadable(name)
        case .stalled:
            reader.cancelReading()
            writer.cancelWriting()
            throw AgentServiceError.invalidInput(
                "Подготовка анимации \(name) зависла: добавьте анимацию в проект ещё раз.")
        case .failed(let error):
            Logger.export.error(
                "Overlay frame failed: \(String(describing: writer.error ?? error), privacy: .public)")
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }
    }

    private static func outputSettings(for video: SourceVideo) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.proRes4444,
            AVVideoWidthKey: video.width,
            AVVideoHeightKey: video.height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
    }

    private static func unreadable(_ name: String) -> AgentServiceError {
        .invalidInput("Не удалось прочитать анимацию \(name): \(renderHint).")
    }

    private static var writeFailed: AgentServiceError {
        .invalidInput(
            "Не удалось сохранить подготовленную копию анимации: "
                + "проверьте свободное место на диске и права на папку проекта.")
    }

    // MARK: - Кадр

    /// YCbCr с альфой → BGRA по выбранной матрице → premultiplied, с пометками для писателя.
    /// Живёт на очереди насоса, отсюда @unchecked Sendable.
    private final class FrameConverter: @unchecked Sendable {
        private let session: VTPixelTransferSession
        private let pool: CVPixelBufferPool
        private let matrix: CFString
        private let premultiply: Bool
        /// Пометки каждого кадра копии: писатель переводит BGRA в YCbCr по той же матрице,
        /// которой помечает файл.
        private let outputAttachments =
            [
                kCVImageBufferAlphaChannelModeKey: kCVImageBufferAlphaChannelMode_PremultipliedAlpha,
                kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
                kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2,
                kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            ] as CFDictionary

        init?(video: SourceVideo, pool: CVPixelBufferPool) {
            var created: VTPixelTransferSession?
            guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &created) == noErr,
                let session = created
            else { return nil }
            self.session = session
            self.pool = pool
            matrix = video.matrix
            premultiply = !video.isPremultiplied
        }

        deinit {
            VTPixelTransferSessionInvalidate(session)
        }

        func convert(_ source: CVPixelBuffer) -> CVPixelBuffer? {
            // Догадку декодера о матрице заменяем своей: без пометки в файле это BT.601.
            CVBufferSetAttachment(source, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
            var created: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created) == kCVReturnSuccess,
                let frame = created
            else { return nil }
            // Буфер из пула помнит пометки прошлого кадра — без них преобразование не подгоняет цвета.
            CVBufferRemoveAllAttachments(frame)
            guard VTPixelTransferSessionTransferImage(session, from: source, to: frame) == noErr else { return nil }
            if premultiply, !premultiplyAlpha(frame) { return nil }
            CVBufferRemoveAllAttachments(frame)
            CVBufferSetAttachments(frame, outputAttachments, .shouldPropagate)
            return frame
        }

        private func premultiplyAlpha(_ frame: CVPixelBuffer) -> Bool {
            CVPixelBufferLockBaseAddress(frame, [])
            defer { CVPixelBufferUnlockBaseAddress(frame, []) }
            guard let base = CVPixelBufferGetBaseAddress(frame) else { return false }
            var buffer = vImage_Buffer(
                data: base, height: vImagePixelCount(CVPixelBufferGetHeight(frame)),
                width: vImagePixelCount(CVPixelBufferGetWidth(frame)),
                rowBytes: CVPixelBufferGetBytesPerRow(frame))
            // Для BGRA подходит вариант RGBA: альфа в обоих последняя, каналы цвета равноправны.
            return vImagePremultiplyData_RGBA8888(&buffer, &buffer, vImage_Flags(kvImageNoFlags)) == kvImageNoError
        }
    }

    // MARK: - Насос

    private enum PumpOutcome {
        case completed, cancelled, readFailed, stalled
        case failed(Error)
    }

    /// Ридер → преобразование → писатель. Кадры и `continuation` живут только на `queue`
    /// (колбэк писателя), как в `Transcoder`: писатель трогают, лишь когда насос отдал итог.
    /// Сторож тикает на своей очереди — чтение кадра может застрять в декодере и занять
    /// очередь насоса. Общее с ним и с отменой задачи лежит под замком. Отсюда @unchecked Sendable.
    /// Только requestMediaDataWhenReady: ручной опрос isReadyForMoreMediaData виснет без RunLoop.
    private final class Pump: @unchecked Sendable {
        private enum StopReason: Sendable {
            case cancelled, stalled

            var outcome: PumpOutcome { self == .cancelled ? .cancelled : .stalled }
        }

        /// Что видят насос, сторож и обработчик отмены задачи.
        private struct Control: Sendable {
            var lastProgress = DispatchTime.now()
            /// Почему насос останавливают снаружи; nil — пусть работает.
            var stopReason: StopReason?
        }

        private let reader: AVAssetReader
        private let output: AVAssetReaderTrackOutput
        private let input: AVAssetWriterInput
        private let adaptor: AVAssetWriterInputPixelBufferAdaptor
        private let converter: FrameConverter
        private let isCancelled: @Sendable () -> Bool
        private let queue = DispatchQueue(label: "montazhka.overlay-normalizer")
        private let watchdogQueue = DispatchQueue(label: "montazhka.overlay-normalizer.watchdog")
        private let control = OSAllocatedUnfairLock(initialState: Control())
        /// Оба меняются только на `queue`.
        private var continuation: CheckedContinuation<PumpOutcome, Never>?
        private var watchdog: DispatchSourceTimer?

        init(
            reader: AVAssetReader, output: AVAssetReaderTrackOutput, input: AVAssetWriterInput,
            adaptor: AVAssetWriterInputPixelBufferAdaptor, converter: FrameConverter,
            isCancelled: @escaping @Sendable () -> Bool
        ) {
            self.reader = reader
            self.output = output
            self.input = input
            self.adaptor = adaptor
            self.converter = converter
            self.isCancelled = isCancelled
        }

        func run(stallLimit: DispatchTimeInterval) async -> PumpOutcome {
            await withCheckedContinuation { continuation in
                queue.async {
                    self.continuation = continuation
                    // Задачу могли отменить ещё до старта: её `finish` тогда пришёл раньше нас.
                    if let stopReason = self.stopReason { return self.finish(stopReason.outcome) }
                    self.control.withLock { $0.lastProgress = .now() }
                    self.startWatchdog(stallLimit: stallLimit)
                    self.input.requestMediaDataWhenReady(on: self.queue) { self.feed() }
                }
            }
        }

        /// Зовётся из обработчика отмены задачи, с любого потока.
        func cancel() {
            stop(.cancelled)
        }

        private var stopReason: StopReason? {
            control.withLock { $0.stopReason }
        }

        /// Остановка снаружи: причину запоминаем, ридер отменяем сразу — это выводит насос
        /// из чтения кадра, застрявшего в декодере, — а итог насос отдаёт на своей очереди.
        private func stop(_ reason: StopReason) {
            let isFirst = control.withLock { state in
                guard state.stopReason == nil else { return false }
                state.stopReason = reason
                return true
            }
            guard isFirst else { return }
            reader.cancelReading()
            queue.async { self.finish(reason.outcome) }
        }

        private func feed() {
            while continuation != nil, input.isReadyForMoreMediaData {
                if let stopReason { return finish(stopReason.outcome) }
                if isCancelled() { return finish(.cancelled) }
                guard let sample = output.copyNextSampleBuffer() else {
                    // Ридер отменили снаружи: итог задаёт причина, а не статус ридера.
                    if let stopReason { return finish(stopReason.outcome) }
                    guard reader.status == .completed else { return finish(.readFailed) }
                    input.markAsFinished()
                    return finish(.completed)
                }
                // Служебные сэмплы без картинки пропускаем.
                guard let frame = CMSampleBufferGetImageBuffer(sample) else { continue }
                guard let converted = converter.convert(frame) else {
                    return finish(.failed(OverlayMediaNormalizer.writeFailed))
                }
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                guard adaptor.append(converted, withPresentationTime: time) else {
                    return finish(.failed(OverlayMediaNormalizer.writeFailed))
                }
                control.withLock { $0.lastProgress = .now() }
            }
        }

        /// Отмена флагом и зависание замечаются, даже если писатель перестал звать колбэк
        /// или чтение кадра застряло в декодере.
        private func startWatchdog(stallLimit: DispatchTimeInterval) {
            let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
            timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
            timer.setEventHandler { [self] in
                if isCancelled() {
                    stop(.cancelled)
                } else if DispatchTime.now() > control.withLock({ $0.lastProgress }) + stallLimit {
                    stop(.stalled)
                }
            }
            watchdog = timer
            timer.resume()
        }

        private func finish(_ outcome: PumpOutcome) {
            guard let continuation else { return }
            self.continuation = nil
            watchdog?.cancel()
            watchdog = nil
            continuation.resume(returning: outcome)
        }
    }
}
