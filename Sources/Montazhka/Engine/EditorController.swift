import Foundation
import AVFoundation
import AppKit
import SwiftUI

/// Сердце монтажки: держит проект, собирает предпросмотр, режет, отменяет, сохраняет.
@MainActor
final class EditorController: ObservableObject {
    @Published private(set) var project: Project
    @Published var currentTime: Double = 0
    @Published var isPlaying = false
    @Published var selectedClipID: UUID?
    @Published var pixelsPerSecond: CGFloat = 24
    @Published var candidates: [PauseCandidate] = []
    @Published var isDetecting = false
    @Published var waveformVersion = 0
    @Published var showPausePanel = false
    @Published var canUndo = false
    @Published var canRedo = false
    @Published var missingFilesMessage: String?

    let player = AVPlayer()
    let waveforms: WaveformStore
    private let store: ProjectStore

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?
    private var previewBoundary: Any?
    private var undoStack: [[Clip]] = []
    private var redoStack: [[Clip]] = []
    private var rebuildGeneration = 0
    private var saveTask: Task<Void, Never>?

    var duration: Double { project.totalDuration }

    init(project: Project, store: ProjectStore) {
        self.project = project
        self.store = store
        self.waveforms = WaveformStore(cacheDir: store.waveformsDir)
        player.actionAtItemEnd = .pause

        checkMissingFiles()
        attachObservers()
        rebuildAndSeek(to: 0)
        warmUpWaveforms()
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    func shutdown() {
        player.pause()
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
        let missing = Set(project.clips.map(\.sourcePath))
            .filter { !FileManager.default.fileExists(atPath: $0) }
        guard !missing.isEmpty else { return }
        project.clips.removeAll { missing.contains($0.sourcePath) }
        let names = missing.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
        missingFilesMessage = "Не нашёл исходные файлы: \(names). Они были перемещены или удалены, поэтому эти клипы убраны с ленты."
        scheduleSave()
    }

    private func warmUpWaveforms() {
        for path in Set(project.clips.map(\.sourcePath)) {
            Task { [weak self] in
                guard let self else { return }
                if await self.waveforms.ensure(path: path) != nil {
                    self.waveformVersion += 1
                }
            }
        }
    }

    // MARK: - Сборка предпросмотра

    private func makeComposition() async -> AVMutableComposition {
        await CompositionBuilder.build(clips: project.clips)
    }

    /// Копия композиции для экспорта.
    func compositionForExport() async -> AVMutableComposition {
        await makeComposition()
    }

    func rebuildAndSeek(to time: Double?) {
        rebuildGeneration += 1
        let generation = rebuildGeneration
        let wasPlaying = player.rate != 0
        player.pause()
        Task { [weak self] in
            guard let self else { return }
            let composition = await self.makeComposition()
            guard generation == self.rebuildGeneration else { return }
            self.player.replaceCurrentItem(with: AVPlayerItem(asset: composition))
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
        currentTime = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
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
        undoStack.append(project.clips)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        updateUndoFlags()
    }

    private func updateUndoFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    private func afterEdit(seekTo time: Double?) {
        candidates = []
        scheduleSave()
        updateUndoFlags()
        rebuildAndSeek(to: time)
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(project.clips)
        project.clips = previous
        afterEdit(seekTo: min(currentTime, duration))
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(project.clips)
        project.clips = next
        afterEdit(seekTo: min(currentTime, duration))
    }

    func addClips(urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            var newClips: [Clip] = []
            for url in urls {
                let asset = AVURLAsset(url: url)
                guard let duration = try? await asset.load(.duration),
                      duration.seconds.isFinite, duration.seconds > 0.1 else { continue }
                newClips.append(Clip(sourcePath: url.path, start: 0, end: duration.seconds))
            }
            guard !newClips.isEmpty else { return }
            self.beginEdit()
            self.project.clips.append(contentsOf: newClips)
            self.afterEdit(seekTo: self.currentTime)
            self.warmUpWaveforms()
        }
    }

    func splitAtPlayhead() {
        guard let (index, offset) = clipPosition(at: currentTime),
              let newClips = TimelineOps.splitting(clips: project.clips, at: index, offset: offset)
        else { return }
        beginEdit()
        project.clips = newClips
        selectedClipID = newClips[index + 1].id
        afterEdit(seekTo: currentTime)
    }

    func deleteClip(id: UUID) {
        guard let index = project.clips.firstIndex(where: { $0.id == id }) else { return }
        beginEdit()
        let newTime = timelineStart(of: index)
        project.clips.remove(at: index)
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
        project.clips.swapAt(index, target)
        afterEdit(seekTo: timelineStart(of: target))
    }

    /// Перестановка во время перетаскивания: только порядок, без пересборки плеера.
    func liveReorder(draggedID: UUID, over targetID: UUID) {
        guard draggedID != targetID,
              let from = project.clips.firstIndex(where: { $0.id == draggedID }),
              let to = project.clips.firstIndex(where: { $0.id == targetID }) else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            project.clips.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    /// Фиксация перетаскивания: записываем шаг отмены и пересобираем предпросмотр.
    func commitReorder(originalOrder: [Clip]) {
        guard originalOrder.map(\.id) != project.clips.map(\.id) else { return }
        let newOrder = project.clips
        project.clips = originalOrder
        beginEdit()
        project.clips = newOrder
        afterEdit(seekTo: currentTime)
    }

    /// Вырезает кусок ленты; лента смыкается сама.
    private func removeTimelineRange(start: Double, end: Double) {
        project.clips = TimelineOps.removingRange(clips: project.clips, start: start, end: end)
    }

    func renameProject(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != project.name else { return }
        project.name = trimmed
        scheduleSave()
    }

    func updateDetectionSettings(_ settings: DetectionSettings) {
        guard settings != project.detection else { return }
        project.detection = settings
        scheduleSave()
    }

    // MARK: - Поиск пауз

    func detectPauses() {
        guard !project.clips.isEmpty else { return }
        isDetecting = true
        let clips = project.clips
        let settings = project.detection
        Task { [weak self] in
            guard let self else { return }
            for path in Set(clips.map(\.sourcePath)) {
                await self.waveforms.ensure(path: path)
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

    /// Проиграть кусок вокруг паузы: чуть до и чуть после.
    func previewCandidate(_ candidate: PauseCandidate) {
        cancelPreviewStop()
        let from = max(0, candidate.fullStart - 0.7)
        let to = min(duration, candidate.fullEnd + 0.7)
        seek(to: from)
        player.play()
        let stopTime = NSValue(time: CMTime(seconds: to, preferredTimescale: 600))
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
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        store.save(project)
    }
}
