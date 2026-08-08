import Foundation
import AVFoundation
import AppKit
import SwiftUI

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

enum FillerDetectionStatus: Equatable {
    case idle
    case transcribing(done: Int, total: Int)
    case failed(String)
}

/// Счётчик поколений асинхронной работы: результат устаревшего поколения отбрасывается.
private struct Generation {
    private var value = 0

    /// Начинает новое поколение и возвращает его номер.
    mutating func advance() -> Int {
        value += 1
        return value
    }

    func isCurrent(_ generation: Int) -> Bool { generation == value }
}

/// Сердце монтажки: держит проект, собирает предпросмотр, режет, отменяет, сохраняет.
@MainActor
final class EditorController: ObservableObject {
    @Published private(set) var project: Project
    @Published var currentTime: Double = 0
    @Published var isPlaying = false
    @Published var selectedClipID: UUID?
    @Published var selectionStart: Double?
    @Published var selectionEnd: Double?
    @Published var pixelsPerSecond: CGFloat = 24
    @Published var candidates: [PauseCandidate] = []
    @Published var isDetecting = false
    @Published var waveformVersion = 0
    @Published var showPausePanel = false
    @Published var showVoicePanel = false
    @Published var showMusicPanel = false
    @Published var showFillerPanel = false
    @Published private(set) var voiceStatus: VoiceEnhanceStatus = .idle
    @Published private(set) var musicProcessing = false
    @Published var canUndo = false
    @Published var canRedo = false
    @Published var missingFilesMessage: String?
    @Published private(set) var missingSources: [MediaReference] = []
    @Published private(set) var saveStatus: ProjectSaveStatus = .idle
    @Published private(set) var renderWarnings: [CompositionWarning] = []
    @Published var fillerCandidates: [FillerCandidate] = []
    @Published private(set) var fillerStatus: FillerDetectionStatus = .idle

    let player = AVPlayer()
    let waveforms: WaveformStore
    let voiceStore: VoiceEnhanceStore
    let musicEQStore: MusicEQStore
    private let store: ProjectStore
    private let mediaPipeline: MediaPipeline
    private let transcriptStore: TranscriptStore

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?
    private var previewBoundary: Any?
    private var projectEditor: ProjectEditor
    private var coalescedEditKind: String?
    private var coalescedEditReset: Task<Void, Never>?
    private var rebuildGeneration = Generation()
    private var saveTask: Task<Void, Never>?
    private var enhancedAudioURLs: [String: URL] = [:]
    private var enhanceDebounce: Task<Void, Never>?
    private var enhanceGeneration = Generation()
    private var musicDebounce: Task<Void, Never>?
    private var seekTask: Task<Void, Never>?
    private var latestSeekTarget: Double?
    private var displaySizeCache: [String: CGSize] = [:]
    private var fillerTask: Task<Void, Never>?
    private var fillerGeneration = Generation()

    var duration: Double { project.totalDuration }
    var timelineSelection: TimelineSelection? {
        guard let selectionStart, let selectionEnd else { return nil }
        return TimelineSelection(start: selectionStart, end: selectionEnd, duration: duration)
    }

    /// Уникальные пути исходных файлов на ленте.
    private var uniqueSourcePaths: Set<String> { Set(project.clips.map(\.sourcePath)) }

    /// Размер кадра первого клипа с учётом поворота — для оценки размера файла в экспорте.
    func sourceDisplaySize() async -> CGSize? {
        guard let clip = project.clips.first else { return nil }
        if let cached = displaySizeCache[clip.sourcePath] { return cached }
        let asset = AVURLAsset(url: clip.url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let naturalSize = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else { return nil }
        let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let display = CGSize(width: abs(rect.width), height: abs(rect.height))
        displaySizeCache[clip.sourcePath] = display
        return display
    }

    init(project: Project, store: ProjectStore) {
        self.project = project
        self.projectEditor = ProjectEditor(project: project)
        self.store = store
        let voiceStore = VoiceEnhanceStore(cacheDir: store.enhancedAudioDir)
        let musicEQStore = MusicEQStore(cacheDir: store.musicEQDir)
        self.waveforms = WaveformStore(cacheDir: store.waveformsDir)
        self.voiceStore = voiceStore
        self.musicEQStore = musicEQStore
        self.mediaPipeline = MediaPipeline(voiceStore: voiceStore, musicEQStore: musicEQStore)
        self.transcriptStore = TranscriptStore(cacheDir: store.transcriptsDir)
        player.actionAtItemEnd = .pause

        checkMissingFiles()
        attachObservers()
        rebuildAndSeek(to: 0)
        warmUpWaveforms()
        // Первый показ — с исходным звуком; улучшенный подменится, когда будет готов
        // (при готовом кэше — почти сразу).
        if project.voiceEnhance.enabled { refreshEnhancedAudio() }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    func shutdown() {
        player.pause()
        cancelFillerDetection()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let terminateObserver { NotificationCenter.default.removeObserver(terminateObserver) }
        saveNow()
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
            MainActor.assumeIsolated { self?.saveNow() }
        }
    }

    private func checkMissingFiles() {
        var seen = Set<UUID>()
        missingSources = project.clips.compactMap { clip in
            guard clip.source.resolvedURL == nil, seen.insert(clip.source.id).inserted else { return nil }
            return clip.source
        }
        guard !missingSources.isEmpty else {
            missingFilesMessage = nil
            return
        }
        let names = missingSources.map(\.displayName).joined(separator: ", ")
        missingFilesMessage = "Не нашёл исходные файлы: \(names). Клипы сохранены — укажи, где теперь лежат файлы."
    }

    /// Переподключает все клипы одного исходника, сохраняя границы монтажа.
    func relinkSource(id: UUID, to url: URL) async -> String? {
        let affected = project.clips.filter { $0.source.id == id }
        guard !affected.isEmpty else { return "Этот исходник уже не используется в проекте." }
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds,
              duration.isFinite,
              duration >= (affected.map(\.end).max() ?? 0) else {
            return "Выбранный файл короче сохранённого монтажа или не читается как видео."
        }
        beginEdit()
        var replacement = affected[0].source
        replacement.relink(to: url)
        applyProjectEdit(.relink(sourceID: id, to: replacement))
        checkMissingFiles()
        warmUpWaveforms()
        afterEdit(seekTo: currentTime)
        return nil
    }

    private func warmUpWaveforms() {
        for path in uniqueSourcePaths {
            Task { [weak self] in
                guard let self else { return }
                if await self.waveforms.ensure(path: path) != nil {
                    self.waveformVersion += 1
                }
            }
        }
    }

    // MARK: - Сборка предпросмотра

    private func makeComposition() async -> (composition: AVMutableComposition, audioMix: AVAudioMix?) {
        let result = await renderComposition(mode: .preview)
        return (result.composition, result.audioMix)
    }

    /// Композиция для экспорта. Если улучшение включено — дожидается обработки всех
    /// исходников; при неудаче отдаёт оригинальный звук и текст предупреждения.
    func compositionForExport() async -> (composition: AVMutableComposition,
                                          audioMix: AVAudioMix?,
                                          audioWarning: String?) {
        let result = await renderComposition(mode: .export)
        let warning = result.warnings.isEmpty
            ? nil
            : result.warnings.map(\.message).joined(separator: "\n")
        return (result.composition, result.audioMix, warning)
    }

    private func renderComposition(mode: MediaRenderMode) async -> MediaRenderResult {
        let processesMusic = project.music.enabled && project.music.eqEnabled
        if processesMusic { musicProcessing = true }
        let request = MediaRenderRequest(project: project,
                                         mode: mode,
                                         readyEnhancedAudio: enhancedAudioURLs)
        let result = await mediaPipeline.render(request)
        if processesMusic { musicProcessing = false }
        if mode == .preview { renderWarnings = result.warnings }
        return result
    }

    func rebuildAndSeek(to time: Double?) {
        let generation = rebuildGeneration.advance()
        let wasPlaying = player.rate != 0
        player.pause()
        Task { [weak self] in
            guard let self else { return }
            let (composition, audioMix) = await self.makeComposition()
            guard self.rebuildGeneration.isCurrent(generation) else { return }
            let item = AVPlayerItem(asset: composition)
            item.audioMix = audioMix
            self.player.replaceCurrentItem(with: item)
            if let time {
                let clamped = min(max(0, time), max(0, self.duration - 0.001))
                await self.player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                                       toleranceBefore: .zero, toleranceAfter: .zero)
                self.currentTime = clamped
            }
            if wasPlaying { self.player.play() }
        }
    }

    // MARK: - Воспроизведение

    func togglePlay() {
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
        currentTime = clamped          // курсор следует за мышью мгновенно
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
        projectEditor.apply(edit, recordHistory: false)
        project = projectEditor.project
    }

    private func afterEdit(seekTo time: Double?) {
        candidates = []
        cancelFillerDetection()
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
        checkMissingFiles()
        candidates = []
        cancelFillerDetection()
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
        Task { [weak self] in
            guard let self else { return }
            // Длительности читаем параллельно; порядок восстанавливаем по индексу.
            let loaded = await withTaskGroup(of: (Int, URL, Double?).self) { group in
                for (i, url) in urls.enumerated() {
                    group.addTask {
                        let seconds = (try? await AVURLAsset(url: url).load(.duration))?.seconds
                        let valid = (seconds?.isFinite == true && (seconds ?? 0) > 0.1) ? seconds : nil
                        return (i, url, valid)
                    }
                }
                var acc: [(Int, URL, Double?)] = []
                for await result in group { acc.append(result) }
                return acc.sorted { $0.0 < $1.0 }
            }
            let newClips = loaded.compactMap { _, url, seconds in
                seconds.map { Clip(sourceURL: url, start: 0, end: $0) }
            }
            guard !newClips.isEmpty else { return }
            self.beginEdit()
            self.applyProjectEdit(.replaceClips(self.project.clips + newClips))
            self.afterEdit(seekTo: self.currentTime)
            self.warmUpWaveforms()
            if self.project.voiceEnhance.enabled { self.refreshEnhancedAudio() }
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
              let to = project.clips.firstIndex(where: { $0.id == targetID }) else { return }
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
        applyProjectEdit(.replaceClips(
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
        voiceStore.cancelAll()

        guard project.voiceEnhance.enabled else {
            enhancedAudioURLs = [:]
            voiceStatus = .idle
            rebuildAndSeek(to: currentTime)
            return
        }

        let settings = project.voiceEnhance
        let sources = Array(uniqueSourcePaths)
        guard !sources.isEmpty else {
            voiceStatus = .idle
            return
        }
        voiceStatus = .rendering(done: 0, total: sources.count)

        Task { [weak self] in
            guard let self else { return }
            guard let ready = await self.renderEnhancedAudio(sources: sources,
                                                             settings: settings,
                                                             generation: generation) else { return }
            self.enhancedAudioURLs = ready
            self.voiceStatus = .idle
            self.rebuildAndSeek(to: self.currentTime)
        }
    }

    /// Прогоняет все исходники через обработку голоса, обновляя счётчик прогресса.
    /// Возвращает nil, если пересчёт устарел, отменён или завершился ошибкой.
    private func renderEnhancedAudio(sources: [String],
                                     settings: VoiceEnhanceSettings,
                                     generation: Int) async -> [String: URL]? {
        var ready: [String: URL] = [:]
        for (index, path) in sources.enumerated() {
            do {
                ready[path] = try await voiceStore.ensure(source: path, settings: settings)
            } catch is CancellationError {
                return nil // уже идёт новый пересчёт
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
        isDetecting = true
        let clips = project.clips
        let settings = project.detection
        Task { [weak self] in
            guard let self else { return }
            // Волны всех файлов считаем параллельно: ensure внутри распаковывает звук
            // в отдельной задаче, поэтому последовательный await зря терял время.
            await withTaskGroup(of: Void.self) { group in
                for path in Set(clips.map(\.sourcePath)) {
                    group.addTask { await self.waveforms.ensure(path: path) }
                }
            }
            let found = SilenceDetector.findPauses(
                clips: clips,
                peaksFor: { self.waveforms.peaks(for: $0) },
                settings: settings
            )
            self.waveformVersion += 1
            self.candidates = found
            self.isDetecting = false
        }
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

    // MARK: - Слова-паразиты

    func detectFillers() {
        guard !project.clips.isEmpty else { return }
        fillerTask?.cancel()
        let generation = fillerGeneration.advance()
        var seen = Set<UUID>()
        let sources = project.clips.compactMap { clip in
            seen.insert(clip.source.id).inserted ? clip.source : nil
        }
        fillerCandidates = []
        fillerStatus = .transcribing(done: 0, total: sources.count)
        fillerTask = Task { [weak self] in
            guard let self else { return }
            var tokens: [TranscriptToken] = []
            do {
                for (index, source) in sources.enumerated() {
                    try Task.checkCancellation()
                    tokens.append(contentsOf: try await self.transcriptStore.ensure(source: source))
                    guard self.fillerGeneration.isCurrent(generation) else { return }
                    self.fillerStatus = .transcribing(done: index + 1, total: sources.count)
                }
                guard self.fillerGeneration.isCurrent(generation) else { return }
                self.fillerCandidates = FillerDetector.findCandidates(clips: self.project.clips,
                                                                      tokens: tokens)
                self.fillerStatus = .idle
            } catch is CancellationError {
                if self.fillerGeneration.isCurrent(generation) { self.fillerStatus = .idle }
            } catch {
                guard self.fillerGeneration.isCurrent(generation) else { return }
                self.fillerStatus = .failed(error.localizedDescription)
            }
        }
    }

    func cancelFillerDetection() {
        _ = fillerGeneration.advance()
        fillerTask?.cancel()
        fillerTask = nil
        fillerCandidates = []
        fillerStatus = .idle
    }

    func toggleFillerCandidate(_ id: UUID) {
        guard let index = fillerCandidates.firstIndex(where: { $0.id == id }) else { return }
        fillerCandidates[index].enabled.toggle()
    }

    func setAllFillerCandidates(enabled: Bool) {
        for index in fillerCandidates.indices { fillerCandidates[index].enabled = enabled }
    }

    func previewFillerCandidate(_ candidate: FillerCandidate) {
        previewRange(start: max(0, candidate.start - 0.7),
                     end: min(duration, candidate.end + 0.7))
    }

    func cutEnabledFillers() {
        let ranges = mergedRanges(fillerCandidates.filter(\.enabled).map { ($0.start, $0.end) })
        guard !ranges.isEmpty else { return }
        beginEdit()
        for range in ranges.reversed() {
            removeTimelineRange(start: range.start, end: range.end)
        }
        afterEdit(seekTo: min(currentTime, duration))
    }

    private func mergedRanges(_ ranges: [(Double, Double)]) -> [(start: Double, end: Double)] {
        let sorted = ranges.sorted { $0.0 < $1.0 }
        var result: [(start: Double, end: Double)] = []
        for range in sorted {
            if let last = result.last, range.0 <= last.end {
                result[result.count - 1].end = max(last.end, range.1)
            } else {
                result.append((range.0, range.1))
            }
        }
        return result
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
        saveTask?.cancel()
        saveStatus = .saving
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        do {
            try store.save(project)
            saveStatus = .saved
        } catch {
            saveStatus = .failed(error.localizedDescription)
        }
    }

    func dismissSaveError() {
        if case .failed = saveStatus {
            saveStatus = .idle
        }
    }
}
