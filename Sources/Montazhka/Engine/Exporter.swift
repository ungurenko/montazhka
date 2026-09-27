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

/// Откуда берётся размер кадра готового файла.
enum PreparedSizing { case composition, quality }

/// Сохранение готового видео в MP4 с прогрессом.
struct PreparedExport {
    let composition: AVComposition
    let audioMix: AVAudioMix?
    let warning: String?
    /// Своя картинка кадра (черновик шортса: вертикаль). nil — как есть.
    var videoComposition: AVVideoComposition? = nil
    /// Надписи поверх кадра (вшитые субтитры, хук); nil — без них.
    var overlay: (@Sendable (Double) -> CGImage?)? = nil
    var subtitleCues: [ShortsSubtitleCue]? = nil
    var subtitlesSkippedReason: String? = nil
    var normalizeLoudness: Bool = true
    /// `ExportProvenance.fingerprint(for:)` — для проверки готового файла.
    var projectFingerprint: String? = nil
    /// Черновик шортса — размер задаёт композиция; обычный проект — качество.
    var sizing: PreparedSizing = .composition
    /// `Project.exportInputFiles`: поверх них файл не записывается.
    var protectedInputs: [URL] = []
}

/// Что происходит до записи файла — подпись в окне.
enum ExportPreparationStep: Equatable, Sendable {
    /// Сборка дорожек и обработка звука.
    case assembling
    /// Расшифровка речи для субтитров; доля nil — неизвестна.
    case transcribing(Double?)

    var activitySnapshot: ActivitySnapshot {
        switch self {
        case .assembling:
            ActivitySnapshot(stageIndex: 0, caption: "Собираю дорожки и обрабатываю звук", progress: .indeterminate)
        case .transcribing(let fraction):
            ActivitySnapshot(
                stageIndex: 0, caption: "Распознаю речь",
                progress: fraction.map { .fraction($0) } ?? .indeterminate)
        }
    }
}

extension FinalExportStage {
    /// Шаг в `ActivityStagePlan.export`.
    var activityStageIndex: Int {
        switch self {
        case .measuring, .mastering: 1
        case .writing: 2
        case .verifying: 3
        }
    }
}

@MainActor
protocol ExportPreparing {
    /// Файлы, из которых собирается ролик: поверх них экспорт не пишет.
    var exportInputFiles: [URL] { get }
    /// `step` зовётся с любого потока.
    func prepareExport(step: @escaping @Sendable (ExportPreparationStep) -> Void) async throws -> PreparedExport
}

@MainActor
protocol VideoExporting {
    func export(
        _ prepared: PreparedExport,
        quality: ExportQuality,
        to url: URL,
        progress: @escaping @Sendable (Double) -> Void,
        stage: @escaping @Sendable (FinalExportStage) -> Void
    ) async throws -> FinalExportReport
}

@MainActor
struct TranscodingVideoExporter: VideoExporting {
    func export(
        _ prepared: PreparedExport,
        quality: ExportQuality,
        to url: URL,
        progress: @escaping @Sendable (Double) -> Void,
        stage: @escaping @Sendable (FinalExportStage) -> Void = { _ in }
    ) async throws -> FinalExportReport {
        let job = FinalExportJob(
            input: ExportInput(
                composition: prepared.composition, audioMix: prepared.audioMix,
                videoComposition: prepared.videoComposition, overlay: prepared.overlay),
            quality: quality,
            sizing: prepared.sizing == .composition ? .composition : .quality(quality),
            subtitleCues: prepared.subtitleCues,
            subtitlesSkippedReason: prepared.subtitlesSkippedReason,
            normalizeLoudness: prepared.normalizeLoudness,
            projectFingerprint: prepared.projectFingerprint,
            protectedInputs: prepared.protectedInputs)
        return try await FinalExport.run(job, to: url, progress: progress, stage: stage)
    }
}

@MainActor
@Observable
final class ExportModel {
    enum State: Equatable {
        case idle
        case preparing
        case exporting
        case done(URL, FinalExportReport)
        case failed(UserFacingError)
    }

    private(set) var state: State = .idle
    /// Общая доля записи 0…1 по всем проходам: громкость, запись, проверка.
    private(set) var progress: Double = 0
    private(set) var audioWarning: String?
    /// Какой проход записи идёт сейчас.
    private(set) var exportStage: FinalExportStage = .writing
    /// Что делается прямо сейчас: та же подпись, что в полосе активности и Доке.
    /// nil — экспорт не идёт.
    private(set) var stageCaption: String?

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
            apply(ExportPreparationStep.assembling.activitySnapshot)
        case .exporting:
            applyExportSnapshot()
        case .done:
            stageCaption = nil
            activity.finish(.export, outcome: .success("Видео сохранено"))
        case .failed(let message):
            stageCaption = nil
            activity.finish(.export, outcome: .failure(message))
        case .idle:
            stageCaption = nil
            activity.finish(.export, outcome: .cancelled)
        }
    }

    /// Подпись окна и центр активности меняются вместе — расходиться им не с чего.
    private func apply(_ snapshot: ActivitySnapshot) {
        stageCaption = snapshot.caption
        activity.apply(.export, snapshot: snapshot)
    }

    private func applyExportSnapshot() {
        apply(
            ActivitySnapshot(
                stageIndex: exportStage.activityStageIndex,
                caption: exportStage.caption,
                progress: .fraction(progress)))
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
        let onStep: @Sendable (ExportPreparationStep) -> Void = { [weak self] step in
            Task { @MainActor in
                guard let self, self.operationGeneration.isCurrent(generation), self.state == .preparing else { return }
                self.apply(step.activitySnapshot)
            }
        }
        let onStage: @Sendable (FinalExportStage) -> Void = { [weak self] stage in
            Task { @MainActor in
                guard let self, self.operationGeneration.isCurrent(generation), self.state == .exporting else { return }
                self.exportStage = stage
                self.applyExportSnapshot()
            }
        }
        let onProgress: @Sendable (Double) -> Void = { [weak self] value in
            Task { @MainActor in
                guard let self,
                    self.operationGeneration.isCurrent(generation),
                    self.state == .exporting
                else { return }
                self.progress = max(self.progress, value)
                self.applyExportSnapshot()
            }
        }
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                // До подготовки: расшифровка и обработка звука не тратятся на заведомый отказ.
                try ExportDestinationGuard.check(url, inputs: preparer.exportInputFiles)
                let prepared = try await preparer.prepareExport(step: onStep)
                try Task.checkCancellation()
                guard self.operationGeneration.isCurrent(generation) else { return }
                self.audioWarning = prepared.warning
                self.exportStage = prepared.normalizeLoudness ? .measuring : .writing
                self.setState(.exporting)
                let report = try await self.videoExporter.export(
                    prepared,
                    quality: quality,
                    to: url,
                    progress: onProgress,
                    stage: onStage
                )
                try Task.checkCancellation()
                guard self.operationGeneration.isCurrent(generation) else { return }
                self.setState(.done(url, report), progress: 1)
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
