import AVFoundation
import AppKit
import Foundation
import OSLog
import Observation
import SwiftUI

func uniqueMediaSources(in clips: [Clip]) -> [MediaReference] {
    var seen = Set<UUID>()
    return clips.compactMap { clip in
        seen.insert(clip.source.id).inserted ? clip.source : nil
    }
}

/// Состояние обработки улучшенного звука.
enum VoiceEnhanceStatus: Equatable {
    case idle
    case rendering(done: Int, total: Int)
    case failed(String)
}

enum ProjectSaveStatus: Equatable {
    case idle
    case saving
    case saved
    case failed(String)
}

enum PreviewState: Equatable {
    case empty
    case preparing
    case ready
    case failed(String)
}

enum ClipImportState: Equatable {
    case idle
    case importing
    case failed(String)
}

private struct ClipLoadResult: Sendable {
    let index: Int
    let url: URL
    let duration: Double?
    let error: String?
}

enum OpenRouterKeyStatus: Equatable, Sendable {
    case missing
    case checking
    case saved
    case failed(String)
}

/// Сердце монтажки: держит проект, собирает предпросмотр, режет, отменяет, сохраняет.
@MainActor
@Observable
final class EditorController: ExportPreparing {
    private(set) var project: Project
    var currentTime: Double = 0
    var isPlaying = false
    var selectedClipID: UUID?
    var selectionStart: Double?
    var selectionEnd: Double?
    var pixelsPerSecond: CGFloat = 24
    var candidates: [PauseCandidate] {
        get { waveformAnalysis.candidates }
        set { waveformAnalysis.candidates = newValue }
    }
    var isDetecting: Bool { waveformAnalysis.isDetecting }
    var waveformVersion: Int { waveformAnalysis.version }
    var showPausePanel = false
    var showVoicePanel = false
    var showMusicPanel = false
    var showSmartEditPanel = false
    private(set) var voiceStatus: VoiceEnhanceStatus = .idle
    private(set) var musicProcessing = false
    var canUndo = false
    var canRedo = false
    var missingFilesMessage: String? {
        get { mediaAvailability.message }
        set { mediaAvailability.message = newValue }
    }
    var missingSources: [MediaReference] { mediaAvailability.missingSources }
    var saveStatus: ProjectSaveStatus { saveCoordinator.status }
    private(set) var renderWarnings: [CompositionWarning] = []
    private(set) var previewState: PreviewState = .empty
    private(set) var clipImportState: ClipImportState = .idle
    var smartEditCandidates: [SmartEditCandidate] = []
    private(set) var smartEditStatus: SmartEditStatus = .idle
    var openRouterKeyStatus: OpenRouterKeyStatus { openRouterKeyManager.status }
    var smartEditModel: SmartEditModel = SmartEditModel.saved() {
        didSet {
            smartEditModel.save(in: preferences)
            refreshSmartEditReasoningOptions()
        }
    }
    var smartEditReasoning: ReasoningChoice = ReasoningChoice.saved(key: EditorController.smartEditReasoningKey) {
        didSet { smartEditReasoning.save(key: EditorController.smartEditReasoningKey, in: preferences) }
    }
    /// Варианты пикера размышлений по возможностям модели; до загрузки
    /// каталога — только «Авто».
    private(set) var smartEditReasoningOptions: [ReasoningChoice] = [.auto]

    let player = AVPlayer()
    let waveforms: WaveformStore
    private let waveformAnalysis: WaveformAnalysisCoordinator
    private let mediaAvailability = MediaAvailabilityMonitor()
    private let mediaAccess = MediaAccessCoordinator()
    let voiceStore: VoiceEnhanceStore
    let musicEQStore: MusicEQStore
    private let repository: any ProjectRepository
    private let saveCoordinator: ProjectSaveCoordinator
    private let mediaPipeline: MediaPipeline
    private let transcriptStore: TranscriptStore
    private let smartEditService: SmartEditService
    private let openRouterClient: OpenRouterClient
    private let openRouterKeyManager: OpenRouterKeyManager
    private let preferences: any PreferenceStoring

    static let smartEditReasoningKey = "smartEdit.reasoningEffort"

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var terminateObserver: NSObjectProtocol?
    @ObservationIgnored private var previewBoundary: Any?
    @ObservationIgnored private var projectEditor: ProjectEditor
    @ObservationIgnored private var coalescedEditKind: String?
    @ObservationIgnored private var coalescedEditReset: Task<Void, Never>?
    @ObservationIgnored private var rebuildGeneration = Generation()
    @ObservationIgnored private var enhancedAudioURLs: [String: URL] = [:]
    @ObservationIgnored private var enhanceDebounce: Task<Void, Never>?
    @ObservationIgnored private var enhanceRenderTask: Task<Void, Never>?
    @ObservationIgnored private var enhanceGeneration = Generation()
    @ObservationIgnored private var musicDebounce: Task<Void, Never>?
    @ObservationIgnored private var seekTask: Task<Void, Never>?
    @ObservationIgnored private var latestSeekTarget: Double?
    @ObservationIgnored private var displaySizeCache: [String: CGSize] = [:]
    @ObservationIgnored private var smartEditTask: Task<Void, Never>?
    @ObservationIgnored private var smartEditGeneration = Generation()
    @ObservationIgnored private var smartEditReasoningTask: Task<Void, Never>?
    @ObservationIgnored private var smartEditReasoningGeneration = Generation()
    @ObservationIgnored private var smartEditSnapshotID: String?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var clipImportTask: Task<Void, Never>?

    var duration: Double { project.totalDuration }
    var timelineSelection: TimelineSelection? {
        guard let selectionStart, let selectionEnd else { return nil }
        return TimelineSelection(start: selectionStart, end: selectionEnd, duration: duration)
    }

    /// Размер кадра первого клипа с учётом поворота — для оценки размера файла в экспорте.
    func sourceDisplaySize() async -> CGSize? {
        guard let clip = project.clips.first else { return nil }
        guard let sourceURL = mediaAccess.url(for: clip.source) else { return nil }
        if let cached = displaySizeCache[sourceURL.path] { return cached }
        let asset = AVURLAsset(url: sourceURL)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
            let naturalSize = try? await track.load(.naturalSize),
            let transform = try? await track.load(.preferredTransform)
        else { return nil }
        let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let display = CGSize(width: abs(rect.width), height: abs(rect.height))
        displaySizeCache[sourceURL.path] = display
        return display
    }

    init(
        project: Project,
        store: any ProjectRepository,
        openRouterKeyStore: any OpenRouterKeyStoring = OpenRouterKeyStore(),
        preferences: any PreferenceStoring = UserDefaultsPreferenceStore.standard
    ) {
        self.project = project
        self.projectEditor = ProjectEditor(project: project)
        self.repository = store
        self.preferences = preferences
        self.saveCoordinator = ProjectSaveCoordinator(repository: store)
        self.openRouterKeyManager = OpenRouterKeyManager(store: openRouterKeyStore)
        let voiceStore = VoiceEnhanceStore(cacheDir: store.directories.enhancedAudio)
        let musicEQStore = MusicEQStore(cacheDir: store.directories.musicEQ)
        let waveformStore = WaveformStore(cacheDir: store.directories.waveforms)
        self.waveforms = waveformStore
        self.waveformAnalysis = WaveformAnalysisCoordinator(store: waveformStore)
        self.voiceStore = voiceStore
        self.musicEQStore = musicEQStore
        self.mediaPipeline = MediaPipeline(voiceStore: voiceStore, musicEQStore: musicEQStore)
        let transcriptStore = TranscriptStore(
            cacheDir: store.directories.transcripts,
            modelsDir: store.directories.models)
        self.transcriptStore = transcriptStore
        let openRouterClient = OpenRouterClient()
        self.openRouterClient = openRouterClient
        self.smartEditService = SmartEditService(
            transcriptStore: transcriptStore,
            openRouter: openRouterClient,
            waveforms: self.waveforms
        )
        player.actionAtItemEnd = .pause
        mediaAccess.synchronize(uniqueMediaSources(in: project.clips))

        checkMissingFiles()
        attachObservers()
        refreshOpenRouterKeyState()
        rebuildAndSeek(to: 0)
        warmUpWaveforms()
        // Первый показ — с исходным звуком; улучшенный подменится, когда будет готов
        // (при готовом кэше — почти сразу).
        if project.voiceEnhance.enabled { refreshEnhancedAudio() }
    }

    deinit {
        MainActor.assumeIsolated {
            if let timeObserver { player.removeTimeObserver(timeObserver) }
        }
    }

    func shutdown() async {
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        previewState = .empty
        clipImportState = .idle
        previewTask?.cancel()
        clipImportTask?.cancel()
        seekTask?.cancel()
        enhanceDebounce?.cancel()
        enhanceRenderTask?.cancel()
        _ = rebuildGeneration.advance()
        _ = enhanceGeneration.advance()
        smartEditReasoningTask?.cancel()
        _ = smartEditReasoningGeneration.advance()
        await voiceStore.cancelAll()
        cancelSmartEdit()
        openRouterKeyManager.cancel()
        mediaAvailability.cancel()
        mediaAccess.stopAll()
        waveformAnalysis.cancel()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let terminateObserver { NotificationCenter.default.removeObserver(terminateObserver) }
        await saveCoordinator.saveNow(project)
    }

    // MARK: - Наблюдатели

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
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.saveCoordinator.saveBeforeTermination(self.project)
            }
        }
    }

    private func checkMissingFiles() {
        mediaAvailability.check(sources: uniqueMediaSources(in: project.clips))
    }

    /// Переподключает все клипы одного исходника, сохраняя границы монтажа.
    func relinkSource(id: UUID, to url: URL) async -> String? {
        let affected = project.clips.filter { $0.source.id == id }
        guard !affected.isEmpty else { return "Этот исходник уже не используется в проекте." }
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds,
            duration.isFinite,
            duration >= (affected.map(\.end).max() ?? 0)
        else {
            return "Выбранный файл короче сохранённого монтажа или не читается как видео."
        }
        beginEdit()
        var replacement = affected[0].source
        replacement.relink(to: url)
        applyProjectEdit(.relink(sourceID: id, to: replacement))
        afterEdit(seekTo: currentTime)
        return nil
    }

    private func warmUpWaveforms() {
        let sources = uniqueMediaSources(in: project.clips)
        waveformAnalysis.warmUp(paths: sources.compactMap { mediaAccess.url(for: $0)?.path })
    }

    // MARK: - Сборка предпросмотра

    private func makeComposition() async -> MediaRenderResult {
        await renderComposition(mode: .preview)
    }

    /// Композиция для экспорта. Если улучшение включено — дожидается обработки всех
    /// исходников; при неудаче отдаёт оригинальный звук и текст предупреждения.
    func compositionForExport() async -> (
        composition: AVComposition,
        audioMix: AVAudioMix?,
        audioWarning: String?
    ) {
        let result = await renderComposition(mode: .export)
        let warning =
            result.warnings.isEmpty
            ? nil
            : result.warnings.map(\.message).joined(separator: "\n")
        return (result.composition, result.audioMix, warning)
    }

    func prepareExport() async throws -> PreparedExport {
        let result = await compositionForExport()
        return PreparedExport(
            composition: result.composition,
            audioMix: result.audioMix,
            warning: result.audioWarning
        )
    }

    private func renderComposition(mode: MediaRenderMode) async -> MediaRenderResult {
        let processesMusic = project.music.enabled && project.music.eqEnabled
        if processesMusic { musicProcessing = true }
        let request = MediaRenderRequest(
            project: project,
            mode: mode,
            readyEnhancedAudio: enhancedAudioURLs)
        let result = await mediaPipeline.render(request)
        if processesMusic { musicProcessing = false }
        return result
    }

    func rebuildAndSeek(to time: Double?) {
        previewTask?.cancel()
        let generation = rebuildGeneration.advance()
        let wasPlaying = player.rate != 0
        player.pause()
        isPlaying = false
        guard !project.clips.isEmpty else {
            player.replaceCurrentItem(with: nil)
            renderWarnings = []
            previewState = .empty
            return
        }
        previewState = .preparing
        previewTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.makeComposition()
            guard !Task.isCancelled, self.rebuildGeneration.isCurrent(generation) else { return }
            self.renderWarnings = result.warnings
            let composition = result.composition
            let audioMix = result.audioMix
            let duration = composition.duration.seconds
            if !duration.isFinite || duration <= 0.001 {
                let warning = self.renderWarnings.map(\.message).joined(separator: "\n")
                self.player.replaceCurrentItem(with: nil)
                self.previewState = .failed(
                    warning.isEmpty ? "Не удалось прочитать видео из проекта." : warning
                )
                return
            }
            let item = AVPlayerItem(asset: composition)
            item.audioMix = audioMix
            self.player.replaceCurrentItem(with: item)
            if let time {
                let clamped = min(max(0, time), max(0, self.duration - 0.001))
                await self.player.seek(
                    to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
                self.currentTime = clamped
            }
            guard !Task.isCancelled, self.rebuildGeneration.isCurrent(generation) else { return }
            self.previewState = .ready
            if wasPlaying { self.player.play() }
        }
    }

    // MARK: - Воспроизведение

    func togglePlay() {
        guard previewState == .ready else { return }
        if player.rate != 0 {
            player.pause()
        } else {
            if duration > 0, currentTime >= duration - 0.02 { seek(to: 0) }
            player.play()
        }
        isPlaying = player.rate != 0
    }

    func seek(to time: Double) {
        cancelPreviewStop()
        let clamped = min(max(0, time), max(0, duration - 0.001))
        currentTime = clamped  // курсор следует за мышью мгновенно
        // Коалесинг: держим одну перемотку в полёте, цель — всегда самая свежая.
        // Промежуточные цели при быстрой протяжке отбрасываются, картинка не копит отставание.
        latestSeekTarget = clamped
        guard seekTask == nil else { return }
        seekTask = Task { [weak self] in
            guard let self else { return }
            while let target = self.latestSeekTarget {
                self.latestSeekTarget = nil
                await self.player.seek(
                    to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
            }
            self.seekTask = nil
        }
    }

    func stepFrames(_ frames: Int) {
        player.pause()
        seek(to: currentTime + Double(frames) / 30.0)
    }

    // MARK: - Координаты ленты

    func timelineStart(of index: Int) -> Double {
        project.clips.prefix(index).reduce(0) { $0 + $1.duration }
    }

    func clipPosition(at time: Double) -> (index: Int, offset: Double)? {
        var acc = 0.0
        for (i, clip) in project.clips.enumerated() {
            if time < acc + clip.duration { return (i, time - acc) }
            acc += clip.duration
        }
        return nil
    }

    // MARK: - Правки

    private func beginEdit() {
        finishCoalescedEdit()
        projectEditor.recordCurrent()
        updateUndoFlags()
    }

    /// Ползунки шлют много значений подряд — вся серия должна отменяться одним шагом.
    private func beginCoalescedEdit(_ kind: String) {
        if coalescedEditKind != kind {
            projectEditor.recordCurrent()
            coalescedEditKind = kind
            updateUndoFlags()
        }
        coalescedEditReset?.cancel()
        coalescedEditReset = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.coalescedEditKind = nil
        }
    }

    private func finishCoalescedEdit() {
        coalescedEditReset?.cancel()
        coalescedEditReset = nil
        coalescedEditKind = nil
    }

    private func updateUndoFlags() {
        canUndo = projectEditor.canUndo
        canRedo = projectEditor.canRedo
    }

    private func applyProjectEdit(_ edit: ProjectEdit) {
        let previousSources = Set(uniqueMediaSources(in: project.clips))
        projectEditor.apply(edit, recordHistory: false)
        project = projectEditor.project
        let currentSources = Set(uniqueMediaSources(in: project.clips))
        if currentSources != previousSources {
            mediaAccess.synchronize(Array(currentSources))
            checkMissingFiles()
            warmUpWaveforms()
        }
    }

    private func afterEdit(seekTo time: Double?) {
        candidates = []
        cancelSmartEdit()
        clearSelection()
        scheduleSave()
        updateUndoFlags()
        rebuildAndSeek(to: time)
    }

    func undo() {
        finishCoalescedEdit()
        guard let previous = projectEditor.undo() else { return }
        restoreProject(previous)
    }

    func redo() {
        finishCoalescedEdit()
        guard let next = projectEditor.redo() else { return }
        restoreProject(next)
    }

    private func restoreProject(_ snapshot: Project) {
        project = snapshot
        mediaAccess.synchronize(uniqueMediaSources(in: project.clips))
        checkMissingFiles()
        warmUpWaveforms()
        candidates = []
        cancelSmartEdit()
        clearSelection()
        scheduleSave()
        updateUndoFlags()
        if project.voiceEnhance.enabled {
            refreshEnhancedAudio()
        } else {
            enhancedAudioURLs = [:]
            voiceStatus = .idle
            rebuildAndSeek(to: min(currentTime, duration))
        }
    }

    func addClips(urls: [URL]) {
        guard !urls.isEmpty else { return }
        clipImportTask?.cancel()
        clipImportState = .importing
        clipImportTask = Task { [weak self] in
            guard let self else { return }
            // Длительности читаем параллельно; порядок восстанавливаем по индексу.
            let loaded = await withTaskGroup(of: ClipLoadResult.self) { group in
                for (i, url) in urls.enumerated() {
                    group.addTask {
                        guard !Task.isCancelled else {
                            return ClipLoadResult(index: i, url: url, duration: nil, error: nil)
                        }
                        do {
                            let asset = AVURLAsset(url: url)
                            let duration = try await asset.load(.duration).seconds
                            guard duration.isFinite, duration > 0.1 else {
                                return ClipLoadResult(
                                    index: i, url: url, duration: nil,
                                    error: "не удалось определить длительность")
                            }
                            let tracks = try await asset.loadTracks(withMediaType: .video)
                            guard !tracks.isEmpty else {
                                return ClipLoadResult(
                                    index: i, url: url, duration: nil,
                                    error: "в файле нет видеодорожки")
                            }
                            return ClipLoadResult(index: i, url: url, duration: duration, error: nil)
                        } catch {
                            return ClipLoadResult(
                                index: i, url: url, duration: nil,
                                error: error.localizedDescription)
                        }
                    }
                }
                var acc: [ClipLoadResult] = []
                for await result in group { acc.append(result) }
                return acc.sorted { $0.index < $1.index }
            }
            guard !Task.isCancelled else { return }
            let newClips = loaded.compactMap { result in
                result.duration.map { Clip(sourceURL: result.url, start: 0, end: $0) }
            }
            if !newClips.isEmpty {
                self.beginEdit()
                self.applyProjectEdit(.replaceClips(self.project.clips + newClips))
                self.afterEdit(seekTo: self.currentTime)
                if self.project.voiceEnhance.enabled { self.refreshEnhancedAudio() }
            }
            let failures = loaded.compactMap { result -> String? in
                result.error.map { "«\(result.url.lastPathComponent)»: \($0)" }
            }
            self.clipImportState =
                failures.isEmpty
                ? .idle
                : .failed("Не удалось добавить видео:\n" + failures.joined(separator: "\n"))
            self.clipImportTask = nil
        }
    }

    func splitAtPlayhead() {
        let splitTime = currentTime
        guard let (index, offset) = clipPosition(at: currentTime),
            let newClips = TimelineOps.splitting(clips: project.clips, at: index, offset: offset)
        else { return }
        beginEdit()
        applyProjectEdit(.replaceClips(newClips))
        selectedClipID = nil
        afterEdit(seekTo: splitTime)
    }

    func commitTrim(clipID: UUID, edge: TimelineTrimEdge, sourceTime: Double) {
        guard let index = project.clips.firstIndex(where: { $0.id == clipID }) else { return }
        let newClips = TimelineOps.shorteningClip(
            clips: project.clips, id: clipID, edge: edge, sourceTime: sourceTime
        )
        guard newClips != project.clips else { return }
        let trimmedClip = newClips[index]
        let boundaryTime =
            timelineStart(of: index)
            + (edge == .end ? trimmedClip.duration : 0)

        beginEdit()
        applyProjectEdit(.replaceClips(newClips))
        selectedClipID = clipID
        currentTime = min(max(0, boundaryTime), duration)
        afterEdit(seekTo: currentTime)
    }

    func deleteClip(id: UUID) {
        guard let index = project.clips.firstIndex(where: { $0.id == id }) else { return }
        beginEdit()
        let newTime = timelineStart(of: index)
        var clips = project.clips
        clips.remove(at: index)
        applyProjectEdit(.replaceClips(clips))
        if selectedClipID == id { selectedClipID = nil }
        afterEdit(seekTo: min(newTime, duration))
    }

    func deleteSelectedClip() {
        if let id = selectedClipID { deleteClip(id: id) }
    }

    func moveClip(id: UUID, direction: Int) {
        guard let index = project.clips.firstIndex(where: { $0.id == id }) else { return }
        let target = index + direction
        guard target >= 0, target < project.clips.count else { return }
        beginEdit()
        var clips = project.clips
        clips.swapAt(index, target)
        applyProjectEdit(.replaceClips(clips))
        afterEdit(seekTo: timelineStart(of: target))
    }

    /// Перестановка во время перетаскивания: только порядок, без пересборки плеера.
    func liveReorder(draggedID: UUID, over targetID: UUID) {
        guard draggedID != targetID,
            let from = project.clips.firstIndex(where: { $0.id == draggedID }),
            let to = project.clips.firstIndex(where: { $0.id == targetID })
        else { return }
        if !smartEditCandidates.isEmpty || smartEditTask != nil { cancelSmartEdit() }
        var clips = project.clips
        clips.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        withAnimation(.easeInOut(duration: 0.15)) {
            applyProjectEdit(.replaceClips(clips))
        }
    }

    /// Фиксация перетаскивания: записываем шаг отмены и пересобираем предпросмотр.
    func commitReorder(originalOrder: [Clip]) {
        guard originalOrder.map(\.id) != project.clips.map(\.id) else { return }
        let newOrder = project.clips
        applyProjectEdit(.replaceClips(originalOrder))
        beginEdit()
        applyProjectEdit(.replaceClips(newOrder))
        afterEdit(seekTo: currentTime)
    }

    /// Вырезает кусок ленты; лента смыкается сама.
    private func removeTimelineRange(start: Double, end: Double) {
        applyProjectEdit(
            .replaceClips(
                TimelineOps.removingRange(clips: project.clips, start: start, end: end)
            ))
    }

    // MARK: - Выделение диапазона

    func setSelection(start: Double, end: Double) {
        selectionStart = min(max(0, start), duration)
        selectionEnd = min(max(0, end), duration)
    }

    func markSelectionStart() { selectionStart = currentTime }
    func markSelectionEnd() { selectionEnd = currentTime }

    func clearSelection() {
        selectionStart = nil
        selectionEnd = nil
    }

    func cutSelection() {
        guard let selection = timelineSelection else { return }
        beginEdit()
        removeTimelineRange(start: selection.start, end: selection.end)
        afterEdit(seekTo: min(selection.start, duration))
    }

    func previewSelection() {
        guard let selection = timelineSelection else { return }
        cancelPreviewStop()
        seek(to: selection.start)
        player.play()
        let stopTime = NSValue(time: CMTime(seconds: selection.end, preferredTimescale: 600))
        previewBoundary = player.addBoundaryTimeObserver(forTimes: [stopTime], queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                self?.player.pause()
                self?.cancelPreviewStop()
            }
        }
    }

    func renameProject(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != project.name else { return }
        beginEdit()
        applyProjectEdit(.rename(trimmed))
        scheduleSave()
    }

    func updateDetectionSettings(_ settings: DetectionSettings) {
        guard settings != project.detection else { return }
        beginCoalescedEdit("detection")
        applyProjectEdit(.updateDetection(settings))
        scheduleSave()
    }

    // MARK: - Фоновая музыка

    func updateMusicSettings(_ settings: MusicSettings) {
        guard settings != project.music else { return }
        beginCoalescedEdit("music")
        let onlyVolumeChanged = settings.differsOnlyByVolume(from: project.music)
        applyProjectEdit(.updateMusic(settings))
        scheduleSave()
        // Ползунок громкости шлёт значения непрерывно — пересобираем после паузы.
        musicDebounce?.cancel()
        if onlyVolumeChanged {
            musicDebounce = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                self?.rebuildAndSeek(to: self?.currentTime)
            }
        } else {
            rebuildAndSeek(to: currentTime)
        }
    }

    // MARK: - Улучшение голоса

    func updateVoiceSettings(_ settings: VoiceEnhanceSettings) {
        guard settings != project.voiceEnhance else { return }
        beginCoalescedEdit("voice")
        applyProjectEdit(.updateVoice(settings))
        scheduleSave()
        // Пока крутят ползунки — ждём паузу 600 мс и только потом пересчитываем.
        enhanceDebounce?.cancel()
        enhanceDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.refreshEnhancedAudio()
        }
    }

    /// Пересчитывает улучшенный звук для всех исходников и подменяет его в предпросмотре.
    /// До готовности играет прежний звук.
    private func refreshEnhancedAudio() {
        let generation = enhanceGeneration.advance()
        enhanceRenderTask?.cancel()
        let settings = project.voiceEnhance
        let sources = Array(
            Set(uniqueMediaSources(in: project.clips).compactMap { mediaAccess.url(for: $0)?.path })
        )

        guard settings.enabled else {
            enhancedAudioURLs = [:]
            voiceStatus = .idle
            rebuildAndSeek(to: currentTime)
            enhanceRenderTask = Task { [voiceStore] in await voiceStore.cancelAll() }
            return
        }

        guard !sources.isEmpty else {
            voiceStatus = .idle
            enhanceRenderTask = Task { [voiceStore] in await voiceStore.cancelAll() }
            return
        }
        voiceStatus = .rendering(done: 0, total: sources.count)

        enhanceRenderTask = Task { [weak self] in
            guard let self else { return }
            await self.voiceStore.cancelAll()
            guard !Task.isCancelled, self.enhanceGeneration.isCurrent(generation) else { return }
            guard
                let ready = await self.renderEnhancedAudio(
                    sources: sources,
                    settings: settings,
                    generation: generation)
            else { return }
            guard !Task.isCancelled, self.enhanceGeneration.isCurrent(generation) else { return }
            self.enhancedAudioURLs = ready
            self.voiceStatus = .idle
            self.rebuildAndSeek(to: self.currentTime)
            self.enhanceRenderTask = nil
        }
    }

    /// Прогоняет все исходники через обработку голоса, обновляя счётчик прогресса.
    /// Возвращает nil, если пересчёт устарел, отменён или завершился ошибкой.
    private func renderEnhancedAudio(
        sources: [String],
        settings: VoiceEnhanceSettings,
        generation: Int
    ) async -> [String: URL]? {
        var ready: [String: URL] = [:]
        for (index, path) in sources.enumerated() {
            do {
                ready[path] = try await voiceStore.ensure(source: path, settings: settings)
            } catch is CancellationError {
                return nil  // уже идёт новый пересчёт
            } catch VoiceEnhanceError.noAudioTrack {
                // без звуковой дорожки — оставляем оригинал
            } catch {
                guard enhanceGeneration.isCurrent(generation) else { return nil }
                voiceStatus = .failed("Не удалось обработать звук. Предпросмотр и экспорт — с исходным звуком.")
                enhancedAudioURLs = [:]
                return nil
            }
            guard enhanceGeneration.isCurrent(generation) else { return nil }
            voiceStatus = .rendering(done: index + 1, total: sources.count)
        }
        guard enhanceGeneration.isCurrent(generation) else { return nil }
        return ready
    }

    // MARK: - Поиск пауз

    func detectPauses() {
        guard !project.clips.isEmpty else { return }
        waveformAnalysis.detect(clips: project.clips, settings: project.detection)
    }

    func toggleCandidate(_ id: UUID) {
        guard let index = candidates.firstIndex(where: { $0.id == id }) else { return }
        candidates[index].enabled.toggle()
    }

    func setAllCandidates(enabled: Bool) {
        for index in candidates.indices { candidates[index].enabled = enabled }
    }

    func cutEnabledCandidates() {
        let ranges = candidates.filter(\.enabled)
            .map { (start: $0.start, end: $0.end) }
            .sorted { $0.start > $1.start }
        guard !ranges.isEmpty else { return }
        beginEdit()
        for range in ranges {
            removeTimelineRange(start: range.start, end: range.end)
        }
        afterEdit(seekTo: min(currentTime, duration))
    }

    // MARK: - Умный монтаж

    func refreshOpenRouterKeyState() {
        openRouterKeyManager.refresh()
    }

    func saveAndValidateOpenRouterKey(_ key: String) async {
        await openRouterKeyManager.saveAndValidate(key)
        refreshSmartEditReasoningOptions()
    }

    func validateSavedOpenRouterKey() async {
        await openRouterKeyManager.validateSaved()
    }

    func deleteOpenRouterKey() async {
        if await openRouterKeyManager.delete() { cancelSmartEdit() }
    }

    /// Подтягивает уровни размышлений выбранной модели из каталога OpenRouter.
    /// Без ключа или при сбое сети молча остаёмся на «Авто».
    func refreshSmartEditReasoningOptions() {
        smartEditReasoningTask?.cancel()
        let generation = smartEditReasoningGeneration.advance()
        let requestedModel = smartEditModel
        smartEditReasoningTask = Task { [weak self] in
            guard let self else { return }
            let options: [ReasoningChoice]
            do {
                guard let apiKey = try await self.openRouterKeyManager.load() else { return }
                let capabilities = try await self.openRouterClient.reasoningCapabilities(
                    for: requestedModel, apiKey: apiKey)
                options = ReasoningChoice.options(
                    availableEfforts: capabilities.efforts,
                    mandatory: capabilities.mandatory)
            } catch {
                return
            }
            guard !Task.isCancelled,
                self.smartEditReasoningGeneration.isCurrent(generation),
                self.smartEditModel == requestedModel
            else { return }
            self.smartEditReasoningOptions = options
            if !options.contains(self.smartEditReasoning) {
                self.smartEditReasoning = .auto
            }
            self.smartEditReasoningTask = nil
        }
    }

    func analyzeSmartEdits() {
        guard !project.clips.isEmpty else { return }
        smartEditTask?.cancel()
        let generation = smartEditGeneration.advance()
        let clips = project.clips
        let threshold = project.detection.thresholdDB
        let model = smartEditModel
        let effort = smartEditReasoning.apiEffort
        smartEditCandidates = []
        smartEditSnapshotID = nil
        smartEditStatus = .preparingModel(progress: nil)
        smartEditTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let apiKey = try await self.openRouterKeyManager.load() else {
                    guard self.smartEditGeneration.isCurrent(generation) else { return }
                    self.smartEditStatus = .failed("Сначала сохрани ключ OpenRouter.")
                    return
                }
                let result = try await self.smartEditService.analyze(
                    clips: clips, projectThresholdDB: threshold,
                    model: model, effort: effort, apiKey: apiKey,
                    status: { status in
                        await self.receiveSmartEditStatus(status, generation: generation)
                    })
                guard self.smartEditGeneration.isCurrent(generation) else { return }
                self.smartEditSnapshotID = result.snapshot.id
                self.smartEditCandidates = result.candidates
                self.smartEditStatus = .ready
            } catch is CancellationError {
                if self.smartEditGeneration.isCurrent(generation) { self.smartEditStatus = .idle }
            } catch {
                guard self.smartEditGeneration.isCurrent(generation) else { return }
                self.smartEditStatus = .failed(error.localizedDescription)
            }
        }
    }

    func cancelSmartEdit() {
        _ = smartEditGeneration.advance()
        smartEditTask?.cancel()
        smartEditTask = nil
        smartEditSnapshotID = nil
        smartEditCandidates = []
        smartEditStatus = .idle
    }

    private func receiveSmartEditStatus(_ status: SmartEditStatus, generation: Int) {
        guard smartEditGeneration.isCurrent(generation) else { return }
        smartEditStatus = status
    }

    func toggleSmartEditCandidate(_ id: UUID) {
        guard let index = smartEditCandidates.firstIndex(where: { $0.id == id }) else { return }
        smartEditCandidates[index].enabled.toggle()
    }

    func setAllObviousSmartEdits(enabled: Bool) {
        for index in smartEditCandidates.indices where smartEditCandidates[index].kind != .semanticRepeat {
            smartEditCandidates[index].enabled = enabled
        }
    }

    func previewSmartEditOriginal(_ candidate: SmartEditCandidate) {
        previewRange(
            start: max(0, candidate.timelineStart - 0.7),
            end: min(duration, candidate.timelineEnd + 0.7))
    }

    func previewSmartEditJoin(_ candidate: SmartEditCandidate) {
        let expectedSnapshot = SmartEditSnapshot(clips: project.clips).id
        guard smartEditSnapshotID == expectedSnapshot else {
            smartEditStatus = .failed(SmartEditError.staleAnalysis.localizedDescription)
            return
        }
        var previewProject = project
        previewProject.clips = TimelineOps.removingRange(
            clips: previewProject.clips,
            start: candidate.timelineStart,
            end: candidate.timelineEnd)
        let start = max(0, candidate.timelineStart - 0.7)
        let end = min(previewProject.totalDuration, candidate.timelineStart + 0.7)
        cancelPreviewStop()
        player.pause()
        let generation = rebuildGeneration.advance()
        let readyEnhancedAudio = enhancedAudioURLs
        Task { [weak self] in
            guard let self else { return }
            let result = await self.mediaPipeline.render(
                MediaRenderRequest(
                    project: previewProject, mode: .preview,
                    readyEnhancedAudio: readyEnhancedAudio))
            guard self.rebuildGeneration.isCurrent(generation) else { return }
            let item = AVPlayerItem(asset: result.composition)
            item.audioMix = result.audioMix
            self.player.replaceCurrentItem(with: item)
            await self.player.seek(
                to: CMTime(seconds: start, preferredTimescale: 600),
                toleranceBefore: .zero, toleranceAfter: .zero)
            self.player.play()
            let stop = NSValue(time: CMTime(seconds: end, preferredTimescale: 600))
            self.previewBoundary = self.player.addBoundaryTimeObserver(forTimes: [stop], queue: .main) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.player.pause()
                    self.cancelPreviewStop()
                    self.rebuildAndSeek(to: candidate.timelineStart)
                }
            }
        }
    }

    func applySmartEdits() {
        let expectedSnapshot = SmartEditSnapshot(clips: project.clips).id
        guard smartEditSnapshotID == expectedSnapshot else {
            smartEditStatus = .failed(SmartEditError.staleAnalysis.localizedDescription)
            return
        }
        let ranges = SmartEditRanges.merged(
            smartEditCandidates.filter(\.enabled).map {
                (start: $0.timelineStart, end: $0.timelineEnd)
            })
        guard !ranges.isEmpty else { return }
        let seekTarget = ranges.first?.start ?? currentTime
        beginEdit()
        for range in ranges.reversed() {
            removeTimelineRange(start: range.start, end: range.end)
        }
        afterEdit(seekTo: min(seekTarget, duration))
    }

    /// Проиграть кусок вокруг паузы: чуть до и чуть после.
    func previewCandidate(_ candidate: PauseCandidate) {
        let from = max(0, candidate.fullStart - 0.7)
        let to = min(duration, candidate.fullEnd + 0.7)
        previewRange(start: from, end: to)
    }

    private func previewRange(start: Double, end: Double) {
        cancelPreviewStop()
        seek(to: start)
        player.play()
        let stopTime = NSValue(time: CMTime(seconds: end, preferredTimescale: 600))
        previewBoundary = player.addBoundaryTimeObserver(forTimes: [stopTime], queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                self?.player.pause()
                self?.cancelPreviewStop()
            }
        }
    }

    private func cancelPreviewStop() {
        if let previewBoundary {
            player.removeTimeObserver(previewBoundary)
            self.previewBoundary = nil
        }
    }

    // MARK: - Сохранение

    func scheduleSave() {
        saveCoordinator.schedule(project)
    }

    func saveNow() async {
        await saveCoordinator.saveNow(project)
    }

    func dismissSaveError() {
        saveCoordinator.dismissError()
    }
}

extension EditorController: OpenRouterKeyControlling {}
