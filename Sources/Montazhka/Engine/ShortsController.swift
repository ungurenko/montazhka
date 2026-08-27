@preconcurrency import AVFoundation
import AppKit
import Foundation
import OSLog
import Observation
import SwiftUI

struct ShortsPreviewRequest {
    let candidateID: UUID
    let sourceURL: URL
    let frameSettings: ShortsFrameSettings
}

private struct ShortsBatchExportItem: Sendable {
    let index: Int
    let candidate: ShortCandidate
}

@MainActor
protocol ShortsPreviewBuilding {
    func makeItem(for request: ShortsPreviewRequest) async throws -> AVPlayerItem
}

@MainActor
struct DefaultShortsPreviewBuilder: ShortsPreviewBuilding {
    func makeItem(for request: ShortsPreviewRequest) async throws -> AVPlayerItem {
        let asset = AVURLAsset(url: request.sourceURL)
        let item = AVPlayerItem(asset: asset)
        if let videoComposition = try await ShortsExporter.previewComposition(
            for: asset,
            frameSettings: request.frameSettings
        ) {
            item.videoComposition = videoComposition
        }
        try Task.checkCancellation()
        return item
    }
}

/// Экран нарезки на shorts: анализ отдельного файла, просмотр кандидатов,
/// пакетный экспорт. Живёт независимо от проекта.
@MainActor
@Observable
final class ShortsController {
    private(set) var source: MediaReference
    private(set) var sourceDuration: Double = 0
    private(set) var displaySize = CGSize(width: 1920, height: 1080)
    private(set) var prepareError: String?
    private(set) var previewError: String?

    var count: ShortsCount {
        didSet { count.save(in: preferences) }
    }
    private var frameSettings: ShortsFrameSettings
    var frameMode: ShortsFrameMode {
        get { frameSettings.mode }
        set { updateFrameSettings { $0.mode = newValue } }
    }
    var canvasColor: ShortsCanvasColor {
        get { frameSettings.canvasColor }
        set { updateFrameSettings { $0.canvasColor = newValue } }
    }
    private var subtitleSettings: ShortsSubtitleSettings

    var subtitlesEnabled: Bool {
        get { subtitleSettings.enabled }
        set { updateSubtitleSettings { $0.enabled = newValue } }
    }

    var subtitleStyle: ShortsSubtitleStyle {
        get { subtitleSettings.style }
        set { updateSubtitleSettings { $0.style = newValue } }
    }

    var subtitleSize: ShortsSubtitleSize {
        get { subtitleSettings.size }
        set { updateSubtitleSettings { $0.size = newValue } }
    }
    var quality: ExportQuality = .high

    private(set) var status: ShortsStatus = .idle
    var candidates: [ShortCandidate] = []
    private(set) var transcriptWords: [TranscriptWord] = []
    private(set) var analysisWarnings: [ShortsAnalysisWarning] = []
    private(set) var exportState: ShortsExportState = .idle
    var openRouterKeyStatus: OpenRouterKeyStatus { aiConnection.openRouterKeyStatus }

    let player = AVPlayer()
    let aiConnection: AIConnectionController
    var currentTime: Double = 0
    var isPlaying = false

    let waveforms: WaveformStore
    private let transcriptStore: TranscriptStore
    private let service: ShortsCutService
    private let previewBuilder: any ShortsPreviewBuilding
    private let preferences: any PreferenceStoring

    static let reasoningKey = "shorts.reasoningEffort"

    @ObservationIgnored private let analysisOperation = LatestOperation()
    @ObservationIgnored private let exportOperation = LatestOperation()
    @ObservationIgnored private let prepareOperation = LatestOperation()
    @ObservationIgnored private let previewOperation = LatestOperation()
    @ObservationIgnored private let seekOperation = LatestOperation()
    @ObservationIgnored private var sourceAccess: MediaAccessLease?
    @ObservationIgnored private var previewBoundary: Any?
    @ObservationIgnored private var previewingID: UUID?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var remainingExportItems: [ShortsBatchExportItem] = []
    @ObservationIgnored private var currentExportFolder: URL?

    var fileName: String { source.displayName }

    var subtitleMode: ShortsSubtitleMode {
        subtitleSettings.mode(with: transcriptWords)
    }

    var currentPreviewSubtitle: ShortsSubtitleOverlay? {
        guard let previewingID,
            let candidate = candidates.first(where: { $0.id == previewingID })
        else { return nil }
        return ShortsSubtitleOverlayBuilder.make(
            at: currentTime,
            sourceStart: candidate.start,
            sourceEnd: candidate.end,
            mode: subtitleMode)
    }

    private func updateSubtitleSettings(_ update: (inout ShortsSubtitleSettings) -> Void) {
        var next = subtitleSettings
        update(&next)
        guard next != subtitleSettings else { return }
        subtitleSettings = next
        next.save(in: preferences)
        refreshPreviewAfterDisplayChange()
    }

    init(
        sourceURL: URL,
        store: any ProjectRepository,
        openRouterKeyStore: any OpenRouterKeyStoring = OpenRouterKeyStore(),
        previewBuilder: any ShortsPreviewBuilding = DefaultShortsPreviewBuilder(),
        preferences: any PreferenceStoring = UserDefaultsPreferenceStore.standard
    ) {
        let source = MediaReference(url: sourceURL)
        self.source = source
        self.preferences = preferences
        count = ShortsCount.saved(in: preferences)
        subtitleSettings = ShortsSubtitleSettings.saved(in: preferences)
        let waveformStore = WaveformStore(cacheDir: store.directories.waveforms)
        self.waveforms = waveformStore
        let transcriptStore = TranscriptStore(
            cacheDir: store.directories.transcripts,
            modelsDir: store.directories.models)
        self.transcriptStore = transcriptStore
        let openRouter = OpenRouterClient()
        self.aiConnection = AIConnectionController(
            preferences: preferences,
            reasoningPreferenceKey: ShortsController.reasoningKey,
            openRouter: openRouter,
            keyStore: openRouterKeyStore)
        let aiClient = UnifiedAIClient(openRouter: openRouter)
        self.service = ShortsCutService(
            transcriptStore: transcriptStore,
            ai: aiClient,
            waveforms: waveformStore)
        self.previewBuilder = previewBuilder
        frameSettings = ShortsFrameSettings.loadAndMigrate(in: preferences)
        attachObservers()
        // Security-scoped доступ резолвим вне главного потока: внутри лизинга
        // — resolvingBookmarkData и проверки существования (дисковый I/O).
        Task.detached(priority: .userInitiated) { [weak self] in
            let lease = source.makeAccessLease()
            await self?.applySourceAccess(lease)
        }
    }

    func shutdown() async {
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        analysisOperation.cancel()
        exportOperation.cancel()
        prepareOperation.cancel()
        aiConnection.shutdown()
        previewOperation.cancel()
        seekOperation.cancel()
        sourceAccess = nil
        cancelPreviewStop()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    /// Принимает лизинг из фонового резолва: параметр `sending` доказывает
    /// компилятору уникальность объекта (он создан прямо в detached-таске).
    private func applySourceAccess(_ lease: sending MediaAccessLease?) {
        sourceAccess = lease
    }

    // MARK: - Подготовка файла

    /// Читает длительность, видеодорожку и размер кадра выбранного файла.
    func prepare() {
        guard sourceDuration == 0, prepareError == nil else { return }
        let asset = AVURLAsset(url: sourceURL)
        prepareOperation.start { [weak self] token in
            guard let self else { return }
            guard let duration = try? await asset.load(.duration).seconds, duration.isFinite else {
                guard self.prepareOperation.isCurrent(token) else { return }
                self.prepareError = "Не удалось прочитать файл."
                return
            }
            guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first else {
                guard self.prepareOperation.isCurrent(token) else { return }
                self.prepareError = "В файле нет видеодорожки."
                return
            }
            guard self.prepareOperation.isCurrent(token) else { return }
            if let naturalSize = try? await videoTrack.load(.naturalSize),
                let transform = try? await videoTrack.load(.preferredTransform)
            {
                guard self.prepareOperation.isCurrent(token) else { return }
                let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
                self.displaySize = CGSize(width: abs(rect.width), height: abs(rect.height))
            }
            guard self.prepareOperation.isCurrent(token) else { return }
            self.sourceDuration = duration
            if duration < ShortsLimits.minSourceDuration {
                self.prepareError = ShortsError.tooShort.localizedDescription
            }
        }
    }

    private var sourceURL: URL {
        // Пока лизинг резолвится — путь без проверок существования на главном потоке.
        sourceAccess?.url ?? URL(fileURLWithPath: source.lastKnownPath)
    }

    // MARK: - AI-провайдер и ключ OpenRouter

    func refreshOpenRouterKeyState() { aiConnection.refreshOpenRouterKeyState() }

    func saveAndValidateOpenRouterKey(_ key: String) async {
        await aiConnection.saveAndValidateOpenRouterKey(key)
    }

    func validateSavedOpenRouterKey() async {
        await aiConnection.validateSavedOpenRouterKey()
    }

    func deleteOpenRouterKey() async {
        if await aiConnection.deleteOpenRouterKey() { cancelAnalysis() }
    }

    // MARK: - Анализ

    func analyze() {
        guard prepareError == nil, sourceDuration >= ShortsLimits.minSourceDuration else { return }
        let file = source
        let duration = sourceDuration
        let requestedCount = count
        candidates = []
        transcriptWords = []
        analysisWarnings = []
        status = .preparingModel(progress: nil)
        analysisOperation.start { [weak self] token in
            guard let self else { return }
            do {
                let configuration = try await self.aiConnection.requestConfiguration()
                let result = try await self.service.analyze(
                    source: file, sourceDuration: duration, count: requestedCount,
                    configuration: configuration,
                    thresholdDB: DetectionSettings().thresholdDB,
                    status: { status in
                        await self.receiveStatus(status, token: token)
                    })
                guard self.analysisOperation.isCurrent(token) else { return }
                self.transcriptWords = result.transcript
                self.candidates = self.preselected(result.candidates)
                self.analysisWarnings = result.warnings
                self.status = .ready
            } catch is CancellationError {
                if self.analysisOperation.isCurrent(token) { self.status = .idle }
            } catch {
                guard self.analysisOperation.isCurrent(token) else { return }
                self.status = .failed(error.localizedDescription)
            }
        }
    }

    func cancelAnalysis() {
        analysisOperation.cancel()
        candidates = []
        transcriptWords = []
        analysisWarnings = []
        status = .idle
    }

    private func receiveStatus(_ status: ShortsStatus, token: LatestOperation.Token) {
        guard analysisOperation.isCurrent(token) else { return }
        self.status = status
    }

    /// Галочки на top-N по рангу: один клик — и лучшее уже выбрано.
    private func preselected(_ candidates: [ShortCandidate]) -> [ShortCandidate] {
        var result = candidates
        let limit = count.desired ?? result.count
        for index in result.indices {
            result[index].enabled = index < limit
        }
        return result
    }

    func toggleCandidate(_ id: UUID) {
        guard let index = candidates.firstIndex(where: { $0.id == id }) else { return }
        candidates[index].enabled.toggle()
    }

    var selectedCount: Int { candidates.filter(\.enabled).count }

    // MARK: - Просмотр

    func preview(_ candidate: ShortCandidate) {
        previewError = nil
        previewingID = candidate.id
        cancelPreviewStop()
        seekOperation.cancel()
        player.pause()
        isPlaying = false
        let start = max(0, candidate.start)
        let end = min(sourceDuration, candidate.end)
        let request = ShortsPreviewRequest(
            candidateID: candidate.id,
            sourceURL: sourceURL,
            frameSettings: frameSettings
        )
        previewOperation.start { [weak self] token in
            guard let self else { return }
            let item: AVPlayerItem
            do {
                item = try await self.previewBuilder.makeItem(for: request)
                try Task.checkCancellation()
            } catch is CancellationError {
                return
            } catch {
                guard self.previewOperation.isCurrent(token) else { return }
                self.previewError =
                    "Не получилось подготовить просмотр: \(error.localizedDescription)"
                return
            }
            guard self.previewOperation.isCurrent(token) else { return }
            self.player.replaceCurrentItem(with: item)
            await self.player.seek(
                to: CMTime(seconds: start, preferredTimescale: 600),
                toleranceBefore: .zero, toleranceAfter: .zero)
            guard self.previewOperation.isCurrent(token) else { return }
            self.currentTime = start
            self.player.play()
            self.isPlaying = true
            let stop = NSValue(time: CMTime(seconds: end, preferredTimescale: 600))
            self.previewBoundary = self.player.addBoundaryTimeObserver(forTimes: [stop], queue: .main) { [weak self] in
                MainActor.assumeIsolated {
                    self?.player.pause()
                    self?.isPlaying = false
                    self?.cancelPreviewStop()
                }
            }
        }
    }

    func togglePlay() {
        guard player.currentItem != nil else { return }
        if player.rate != 0 {
            player.pause()
        } else {
            if let end = player.currentItem?.duration.seconds,
                end > 0, currentTime >= end - 0.02
            {
                seek(to: 0)
            }
            player.play()
        }
        isPlaying = player.rate != 0
    }

    func seek(to time: Double) {
        let clamped = max(0, time)
        currentTime = clamped
        seekOperation.start { [weak self] token in
            guard let self else { return }
            await self.player.seek(
                to: CMTime(seconds: clamped, preferredTimescale: 600),
                toleranceBefore: .zero, toleranceAfter: .zero)
            guard self.seekOperation.isCurrent(token) else { return }
        }
    }

    /// Настройки отображения поменялись — перезапускаем текущий превью,
    /// чтобы настройки были видны до экспорта.
    private func refreshPreviewAfterDisplayChange() {
        guard let id = previewingID,
            let candidate = candidates.first(where: { $0.id == id })
        else { return }
        preview(candidate)
    }

    private func updateFrameSettings(_ update: (inout ShortsFrameSettings) -> Void) {
        var next = frameSettings
        update(&next)
        guard next != frameSettings else { return }
        frameSettings = next
        next.save(in: preferences)
        refreshPreviewAfterDisplayChange()
    }

    private func cancelPreviewStop() {
        if let previewBoundary {
            player.removeTimeObserver(previewBoundary)
            self.previewBoundary = nil
        }
    }

    private func attachObservers() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = time.seconds
                self.isPlaying = self.player.rate != 0
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isPlaying = false }
        }
    }

    // MARK: - Экспорт

    func chooseFolderAndExport() {
        guard selectedCount > 0 else { return }
        let panel = NSOpenPanel()
        panel.title = "Выбери папку для роликов"
        panel.prompt = "Сохранить"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        startExport(to: folder)
    }

    func startExport(to folder: URL) {
        let selected = candidates.filter(\.enabled)
        guard !selected.isEmpty else { return }
        let items = selected.enumerated().map {
            ShortsBatchExportItem(index: $0.offset, candidate: $0.element)
        }
        remainingExportItems = items
        currentExportFolder = folder
        runExport(items: items, to: folder, completed: 0, total: items.count)
    }

    func retryRemainingExport() {
        guard case .failed(_, let completed, let total, let folder) = exportState,
            !remainingExportItems.isEmpty
        else { return }
        runExport(
            items: remainingExportItems,
            to: folder,
            completed: completed,
            total: total)
    }

    private func runExport(
        items: [ShortsBatchExportItem],
        to folder: URL,
        completed: Int,
        total: Int
    ) {
        let url = sourceURL
        let sourceName = url.deletingPathExtension().lastPathComponent
        let size = displaySize
        let quality = self.quality
        let frameSettings = self.frameSettings
        let subtitleMode = self.subtitleMode
        currentExportFolder = folder
        exportState = .exporting(done: completed, total: total, progress: 0)
        exportOperation.start { [weak self] token in
            guard let self else { return }
            do {
                for (offset, item) in items.enumerated() {
                    let done = completed + offset
                    guard exportOperation.isCurrent(token) else { return }
                    try await ShortsExporter.export(
                        candidate: item.candidate, sourceURL: url, displaySize: size,
                        quality: quality, frameSettings: frameSettings,
                        subtitleMode: subtitleMode,
                        to: ShortsExporter.fileURL(
                            in: folder, sourceName: sourceName,
                            index: item.index, title: item.candidate.title),
                        progress: { fraction in
                            Task { @MainActor [weak self] in
                                guard let self, exportOperation.isCurrent(token),
                                    case .exporting(let currentDone, _, _) = self.exportState,
                                    currentDone == done
                                else { return }
                                self.exportState = .exporting(
                                    done: done, total: total,
                                    progress: fraction)
                            }
                        })
                    guard exportOperation.isCurrent(token) else { return }
                    self.remainingExportItems = Array(items.dropFirst(offset + 1))
                    self.exportState = .exporting(done: done + 1, total: total, progress: 0)
                }
                self.remainingExportItems = []
                self.exportState = .done(folder)
            } catch {
                // Отмена доходит только из cancelExport/перезапуска/shutdown — каждый
                // уже выставил состояние сам; устаревшему запуску писать нельзя.
                guard exportOperation.isCurrent(token), !(error is CancellationError) else { return }
                let done: Int
                if case .exporting(let currentDone, _, _) = self.exportState {
                    done = currentDone
                } else {
                    done = completed
                }
                self.exportState = .failed(
                    message: "Не получилось сохранить ролики: \(error.localizedDescription)",
                    completed: done,
                    total: total,
                    folder: folder)
            }
        }
    }

    func cancelExport() {
        let cancelledState: ShortsExportState
        if case .exporting(let done, let total, _) = exportState,
            done > 0,
            let currentExportFolder
        {
            cancelledState = .failed(
                message: "Экспорт остановлен.",
                completed: done,
                total: total,
                folder: currentExportFolder)
        } else {
            cancelledState = .idle
        }
        exportOperation.cancel()
        exportState = cancelledState
    }

    func revealFolder(_ url: URL) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
    }
}

extension ShortsController: OpenRouterKeyControlling {}
