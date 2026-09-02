@preconcurrency import AVFoundation
import AppKit
import Foundation
import OSLog
import Observation

enum ExportQuality: String, CaseIterable, Identifiable, Sendable {
    case maximum, high, medium, compact

    var id: String { rawValue }

    var title: String {
        switch self {
        case .maximum: "Максимальное"
        case .high: "Высокое"
        case .medium: "Среднее"
        case .compact: "Компактное"
        }
    }

    var subtitle: String {
        switch self {
        case .maximum: "Исходное разрешение, файл заметно больше"
        case .high: "Full HD — отличная картинка"
        case .medium: "Full HD — баланс качества и размера"
        case .compact: "HD 720 — маленький файл для мессенджера"
        }
    }

    /// Потолок меньшей стороны кадра (720 у компактного = «720p» и для вертикальных видео).
    private var sideCap: Double? {
        switch self {
        case .maximum: nil
        case .high, .medium: 1080
        case .compact: 720
        }
    }

    /// Базовый битрейт видео при полном опорном кадре.
    private var baseVideoBitrate: Double {
        switch self {
        case .maximum: 16_000_000
        case .high: 8_000_000
        case .medium: 4_500_000
        case .compact: 2_000_000
        }
    }

    /// Опорная площадь кадра для базового битрейта.
    private var referencePixels: Double {
        switch self {
        case .compact: 1280 * 720
        default: 1920 * 1080
        }
    }

    var audioBitrate: Int {
        switch self {
        case .maximum: 192_000
        case .high: 160_000
        case .medium: 128_000
        case .compact: 96_000
        }
    }

    /// Размер кадра на выходе: потолок по меньшей стороне, без увеличения,
    /// аспект сохраняется, стороны чётные (требование H.264).
    func targetDimensions(forDisplaySize size: CGSize) -> CGSize {
        let width = abs(size.width), height = abs(size.height)
        guard width > 1, height > 1 else { return CGSize(width: 1920, height: 1080) }
        var scale = 1.0
        if let cap = sideCap {
            scale = min(1.0, cap / min(width, height))
        }
        func even(_ value: Double) -> Double { max(2, (value * scale / 2).rounded() * 2) }
        return CGSize(width: even(width), height: even(height))
    }

    /// Битрейт видео масштабируется по площади кадра; меньше 1 Мбит/с не опускаемся.
    func videoBitrate(forDimensions dims: CGSize) -> Int {
        let area = Double(dims.width * dims.height) / referencePixels
        let scaled = baseVideoBitrate * (self == .maximum ? area : min(1, area))
        return max(1_000_000, Int(scaled))
    }

    /// Примерный размер файла: (битрейт видео + звука) × длительность, +4% на контейнер.
    func estimatedBytes(duration: Double, displaySize: CGSize) -> Int64 {
        let dims = targetDimensions(forDisplaySize: displaySize)
        let bitsPerSecond = Double(videoBitrate(forDimensions: dims) + audioBitrate)
        return Int64((bitsPerSecond / 8 * duration * 1.04).rounded())
    }

    /// Текст для окна экспорта: «≈ 180 МБ» или «≈ 1.2 ГБ».
    func estimateText(duration: Double, displaySize: CGSize) -> String {
        let bytes = Double(estimatedBytes(duration: duration, displaySize: displaySize))
        let megabytes = bytes / 1_000_000
        if megabytes >= 1000 {
            return String(format: "≈ %.1f ГБ", bytes / 1_000_000_000)
        }
        return "≈ \(Int(megabytes.rounded())) МБ"
    }
}

/// Сохранение готового видео в MP4 с прогрессом.
struct PreparedExport {
    let composition: AVComposition
    let audioMix: AVAudioMix?
    let warning: String?
}

@MainActor
protocol ExportPreparing {
    func prepareExport() async throws -> PreparedExport
}

@MainActor
protocol VideoExporting {
    func export(
        _ prepared: PreparedExport,
        quality: ExportQuality,
        to url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws
}

@MainActor
struct TranscodingVideoExporter: VideoExporting {
    func export(
        _ prepared: PreparedExport,
        quality: ExportQuality,
        to url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let input = ExportInput(composition: prepared.composition, audioMix: prepared.audioMix)
        let settings = try await Transcoder.settings(for: quality, input: input)
        try await Transcoder.export(
            input: input,
            settings: settings,
            to: url,
            progress: progress
        )
    }
}

@MainActor
@Observable
final class ExportModel {
    enum State: Equatable {
        case idle
        case preparing
        case exporting
        case done(URL)
        case failed(UserFacingError)
    }

    private(set) var state: State = .idle
    private(set) var progress: Double = 0
    private(set) var audioWarning: String?

    @ObservationIgnored private let videoExporter: any VideoExporting
    @ObservationIgnored private let activity: ActivityCenter
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var operationGeneration = Generation()

    init(
        videoExporter: any VideoExporting = TranscodingVideoExporter(),
        activity: ActivityCenter = .shared
    ) {
        self.videoExporter = videoExporter
        self.activity = activity
    }

    /// Единственная точка смены состояния: центр активности узнаёт о ходе
    /// экспорта отсюда, поэтому прогресс виден в Доке даже со свёрнутым окном.
    private func setState(_ new: State, progress: Double? = nil) {
        state = new
        if let progress { self.progress = progress }
        switch new {
        case .preparing:
            activity.apply(
                .export,
                snapshot: ActivitySnapshot(
                    stageIndex: 0,
                    caption: "Собираю дорожки и обрабатываю звук",
                    progress: .indeterminate))
        case .exporting:
            activity.apply(
                .export,
                snapshot: ActivitySnapshot(
                    stageIndex: 1,
                    caption: "Записываю файл",
                    progress: .fraction(self.progress)))
        case .done:
            activity.finish(.export, outcome: .success("Видео сохранено"))
        case .failed(let message):
            activity.finish(.export, outcome: .failure(message))
        case .idle:
            activity.finish(.export, outcome: .cancelled)
        }
    }

    func chooseDestination(projectName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Сохранить видео"
        panel.nameFieldStringValue = "\(projectName).mp4"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        return panel.runModal() == .OK ? panel.url : nil
    }

    @discardableResult
    func start(
        preparer: any ExportPreparing,
        quality: ExportQuality,
        to url: URL
    ) -> Bool {
        guard operationTask == nil else { return false }
        let generation = operationGeneration.advance()
        progress = 0
        audioWarning = nil
        activity.begin(
            .export,
            title: "Сохранение видео",
            stages: ActivityStagePlan.export,
            isCancellable: true,
            cancel: { [weak self] in self?.cancel() })
        setState(.preparing)
        let onProgress: @Sendable (Double) -> Void = { [weak self] value in
            Task { @MainActor in
                guard let self,
                    self.operationGeneration.isCurrent(generation),
                    self.state == .exporting
                else { return }
                self.progress = value
                self.activity.apply(
                    .export,
                    snapshot: ActivitySnapshot(
                        stageIndex: 1,
                        caption: "Записываю файл",
                        progress: .fraction(value)))
            }
        }
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let prepared = try await preparer.prepareExport()
                try Task.checkCancellation()
                guard self.operationGeneration.isCurrent(generation) else { return }
                self.audioWarning = prepared.warning
                self.setState(.exporting)
                try await self.videoExporter.export(
                    prepared,
                    quality: quality,
                    to: url,
                    progress: onProgress
                )
                try Task.checkCancellation()
                guard self.operationGeneration.isCurrent(generation) else { return }
                self.setState(.done(url), progress: 1)
            } catch is CancellationError {
                guard self.operationGeneration.isCurrent(generation) else { return }
                self.setState(.idle, progress: 0)
            } catch {
                guard self.operationGeneration.isCurrent(generation) else { return }
                Logger.export.error("Экспорт не удался: \(error.localizedDescription)")
                self.setState(.failed(UserFacingError.make(error, context: .export)))
            }
            if self.operationGeneration.isCurrent(generation) {
                self.operationTask = nil
            }
        }
        return true
    }

    func cancel() {
        _ = operationGeneration.advance()
        operationTask?.cancel()
        operationTask = nil
        setState(.idle, progress: 0)
        audioWarning = nil
    }

    func retry() {
        guard operationTask == nil else { return }
        state = .idle
        progress = 0
        audioWarning = nil
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
