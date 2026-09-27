@preconcurrency import AVFoundation
import Foundation
import OSLog

/// Откуда берётся размер кадра готового файла.
enum ExportSizing: Sendable {
    /// Размер кадра — `renderSize` видеокомпозиции (черновик шортса).
    case composition
    /// Размер кадра — качество, применённое к кадру самой склейки.
    case quality(ExportQuality)
    /// Готовые размер и битрейты: старое окно шортсов считает их само.
    case settings(Transcoder.Settings)
}

/// Всё, что нужно для записи готового файла из любого входа экспорта.
/// @unchecked Sendable: композиции внутри `input` после сборки только читают.
struct FinalExportJob: @unchecked Sendable {
    var input: ExportInput
    var quality: ExportQuality
    var sizing: ExportSizing
    /// nil — файла субтитров нет.
    var subtitleCues: [ShortsSubtitleCue]?
    /// Почему реплик нет: нет расшифровки, нет модели, нет речи.
    var subtitlesSkippedReason: String?
    var normalizeLoudness: Bool
    /// Из какой версии проекта собран файл: `ExportProvenance.fingerprint(for:)`.
    var projectFingerprint: String?
}

/// Что стало со звуком и субтитрами готового файла.
struct FinalExportReport: Equatable, Sendable {
    var loudness: LoudnessMeasurement?
    var normalized: Bool
    var gainDB: Double
    var targetMet: Bool?
    var subtitlesURL: URL?
    var subtitlesSkippedReason: String?
    var warnings: [String]
}

/// Проход завершающего шага — подпись для окна.
enum FinalExportStage: Sendable, Equatable {
    case measuring, mastering, writing, verifying

    var caption: String {
        switch self {
        case .measuring: "Замеряю громкость"
        case .mastering: "Выравниваю звук"
        case .writing: "Записываю файл"
        case .verifying: "Проверяю громкость"
        }
    }
}

/// Единый завершающий шаг всех входов экспорта: окно, `montazhka_export`,
/// `make_shorts` и старое окно шортсов. Звук выравнивается до −14 LUFS,
/// рядом с видео ложится .srt, в MP4 записывается отпечаток проекта,
/// а громкость готового файла меряется заново.
enum FinalExport {
    static let noSpeechReason = "В ролике нет речи — субтитры не созданы"

    /// `progress` — общая доля 0…1 всех проходов; `stage` — начало каждого прохода.
    /// Видео и .srt пишутся во временные файлы рядом и встают на место последним шагом,
    /// после замера громкости: отмена до этого оставляет прежние файлы нетронутыми,
    /// а после него экспорт уже готов.
    static func run(
        _ job: FinalExportJob, to url: URL,
        progress: @escaping @Sendable (Double) -> Void,
        stage: (@Sendable (FinalExportStage) -> Void)? = nil
    ) async throws -> FinalExportReport {
        let tracker = FinalExportProgress(normalizing: job.normalizeLoudness, report: progress, announce: stage)
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-master-\(UUID().uuidString)", isDirectory: true)
        // Выровненный звук (CAF) живёт только до конца записи — и при ошибке, и при отмене.
        defer { try? FileManager.default.removeItem(at: scratch) }
        // MP4 уже на месте — значит, перезаписывается прошлый экспорт, и его .srt тоже наш.
        let replacesVideo = FileManager.default.fileExists(atPath: url.path)
        let length = try await job.input.composition.load(.duration)
        let duration = length.seconds

        var input = job.input
        var mastered: MasteredAudio?
        if job.normalizeLoudness {
            mastered = try await master(input, duration: duration, scratch: scratch, tracker: tracker)
            if let mastered { input = try await replacingAudio(of: input, with: mastered.audioURL, length: length) }
        }

        var subtitles = SubtitleSidecar(job: job, duration: duration, video: url, replacesVideo: replacesVideo)
        defer { subtitles.discard() }
        var video = AtomicMediaOutput(destinationURL: url)
        defer { video.discard() }
        tracker.begin(.writing)
        try await writeVideo(job, input: input, to: video.temporaryURL, progress: { tracker.update($0) })

        tracker.begin(.verifying)
        let loudness = try? await LoudnessMeter.measure(url: video.temporaryURL, progress: { tracker.update($0) })
        try Task.checkCancellation()
        try video.commit()
        var warnings = subtitles.commit()
        tracker.update(1)
        let targetMet = mastered == nil ? nil : loudness.map(meetsTarget)
        warnings += loudnessWarnings(normalized: mastered != nil, loudness: loudness, targetMet: targetMet)
        return FinalExportReport(
            loudness: loudness, normalized: mastered != nil, gainDB: mastered?.gainDB ?? 0, targetMet: targetMet,
            subtitlesURL: subtitles.committedURL, subtitlesSkippedReason: subtitles.skippedReason, warnings: warnings)
    }

    private static func master(
        _ input: ExportInput, duration: Double, scratch: URL, tracker: FinalExportProgress
    ) async throws -> MasteredAudio? {
        tracker.begin(.measuring)
        return try await LoudnessNormalizer.master(
            asset: input.composition, audioMix: input.audioMix, duration: duration, target: LoudnessTarget(),
            scratchDirectory: scratch, isCancelled: { Task.isCancelled },
            progress: { pass, fraction in
                if pass == .render { tracker.begin(.mastering) }
                tracker.update(fraction)
            })
    }

    /// Звук склейки заменяется выровненным. Меняется сама склейка: номера
    /// видеодорожек нужны видеокомпозиции. Старый микс ссылается на удалённые
    /// дорожки, поэтому его больше нет. Длина склейки остаётся прежней:
    /// выровненный звук — целое число отсчётов и может выйти за конец на долю
    /// отсчёта, а видеокомпозиция описывает ровно прежнюю длину.
    private static func replacingAudio(
        of input: ExportInput, with audioURL: URL, length: CMTime
    ) async throws -> ExportInput {
        guard
            let composition = (input.composition as? AVMutableComposition)
                ?? ((input.composition as? AVComposition)?.mutableCopy() as? AVMutableComposition)
        else { throw LoudnessError.writerFailed }
        try await LoudnessNormalizer.replaceAudio(in: composition, with: audioURL)
        if composition.duration > length {
            let overhang = CMTimeRange(start: length, end: composition.duration)
            for track in composition.tracks(withMediaType: .audio) { track.removeTimeRange(overhang) }
        }
        return ExportInput(composition: composition, audioMix: nil, videoComposition: input.videoComposition)
    }

    private static func meetsTarget(_ loudness: LoudnessMeasurement) -> Bool {
        let target = LoudnessTarget()
        guard let integrated = loudness.integratedLUFS else { return false }
        return abs(integrated - target.integrated) <= 1 && loudness.truePeakDBTP <= target.truePeakCeiling
    }

    private static func loudnessWarnings(
        normalized: Bool, loudness: LoudnessMeasurement?, targetMet: Bool?
    ) -> [String] {
        guard normalized else { return [] }
        guard let loudness else { return ["Не получилось замерить громкость готового файла"] }
        guard targetMet == false else { return [] }
        let integrated = loudness.integratedLUFS.map { String(format: "%.1f", $0) } ?? "—"
        return [
            "Громкость не вышла на стандарт: \(integrated) LUFS, пик \(String(format: "%.1f", loudness.truePeakDBTP)) dBTP"
        ]
    }

    private static func writeVideo(
        _ job: FinalExportJob, input: ExportInput, to url: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let metadata = job.projectFingerprint.map(ExportProvenance.metadataItems(fingerprint:)) ?? []
        let quality: ExportQuality
        switch job.sizing {
        case .settings(let settings):
            try await Transcoder.exportWithOfflineComposition(
                input: input, settings: settings, to: url, metadata: metadata, progress: progress)
            return
        case .composition where input.videoComposition != nil:
            try await Transcoder.export(
                composed: input, quality: job.quality, to: url, metadata: metadata, progress: progress)
            return
        case .composition:
            // Без своей композиции размер кадра задаёт качество.
            quality = job.quality
        case .quality(let sized):
            quality = sized
        }
        // Размер считается по кадру самой склейки, без своей видеокомпозиции.
        let base = ExportInput(composition: input.composition, audioMix: input.audioMix)
        let settings = try await Transcoder.settings(for: quality, input: base)
        if input.videoComposition == nil {
            try await Transcoder.export(
                input: input, settings: settings, to: url, metadata: metadata, progress: progress)
        } else {
            try await Transcoder.exportWithOfflineComposition(
                input: input, settings: settings, to: url, metadata: metadata, progress: progress)
        }
    }
}

/// .srt рядом с видео. Временная копия пишется в папку назначения до видео,
/// на место встаёт только после готового MP4: при ошибке записи прежняя пара
/// «видео + субтитры» остаётся нетронутой. Сбой с субтитрами экспорт не валит.
/// Чужой .srt (рядом ещё не было MP4) не заменяется и не удаляется никогда.
private struct SubtitleSidecar {
    let destination: URL
    private var output: AtomicMediaOutput?
    /// Прежний .srt от прошлого экспорта этого MP4 уходит, если новых фраз нет.
    private var removesStale = false
    private(set) var committedURL: URL?
    private(set) var skippedReason: String?

    /// `replacesVideo` — MP4 по этому пути уже был: перезаписывается прошлый экспорт.
    init(job: FinalExportJob, duration: Double, video: URL, replacesVideo: Bool) {
        destination = SubRipWriter.url(forVideo: video)
        guard let cues = job.subtitleCues else {
            skippedReason = job.subtitlesSkippedReason
            removesStale = replacesVideo
            return
        }
        let fitted = Self.fitted(cues, to: duration)
        guard !fitted.isEmpty else {
            skippedReason = FinalExport.noSpeechReason
            removesStale = replacesVideo
            return
        }
        if !replacesVideo, FileManager.default.fileExists(atPath: destination.path) {
            skippedReason = "Рядом уже есть файл субтитров \(destination.lastPathComponent) — не стал его заменять"
            return
        }
        let pending = AtomicMediaOutput(destinationURL: destination)
        do {
            try Data(SubRipWriter.text(cues: fitted).utf8).write(to: pending.temporaryURL)
            output = pending
        } catch {
            pending.discard()
            skippedReason = Self.failure(error)
        }
    }

    /// Фраза не выходит за конец ролика; фразы после конца выбрасываются.
    static func fitted(_ cues: [ShortsSubtitleCue], to duration: Double) -> [ShortsSubtitleCue] {
        cues.compactMap { cue in
            guard cue.start < duration else { return nil }
            return ShortsSubtitleCue(words: cue.words, start: cue.start, end: min(cue.end, duration))
        }
    }

    /// Видео уже на месте: новый .srt встаёт рядом, а без новых фраз уходит старый —
    /// он от прежнего экспорта этого файла. Не удалось поставить новый — прежний
    /// остаётся. Возвращает предупреждения.
    mutating func commit() -> [String] {
        if var pending = output {
            do {
                try pending.commit()
                output = pending
                committedURL = destination
            } catch {
                pending.discard()
                output = nil
                skippedReason = Self.failure(error)
            }
            return []
        }
        guard removesStale, FileManager.default.fileExists(atPath: destination.path) else { return [] }
        do {
            try FileManager.default.removeItem(at: destination)
            return []
        } catch {
            Logger.export.error("Старые субтитры не удалились: \(String(reflecting: error), privacy: .public)")
            return ["Рядом с видео остались субтитры прошлого экспорта: \(destination.lastPathComponent)"]
        }
    }

    func discard() {
        output?.discard()
    }

    private static func failure(_ error: Error) -> String {
        "Субтитры не сохранились: \(UserFacingError.make(error, context: .export).what)"
    }
}

/// Общая доля завершающего шага из честных долей каждого прохода. Места
/// проходов в общей полосе — примерные веса: дольше всего идёт запись видео.
/// Колбэки приходят с разных очередей, поэтому состояние под замком.
private final class FinalExportProgress: @unchecked Sendable {
    private let lock = NSLock()
    private let spans: [FinalExportStage: ClosedRange<Double>]
    private let report: @Sendable (Double) -> Void
    private let announce: (@Sendable (FinalExportStage) -> Void)?
    private var current: FinalExportStage?
    private var reported = -1.0

    init(
        normalizing: Bool, report: @escaping @Sendable (Double) -> Void,
        announce: (@Sendable (FinalExportStage) -> Void)?
    ) {
        spans =
            normalizing
            ? [.measuring: 0...0.1, .mastering: 0.1...0.25, .writing: 0.25...0.95, .verifying: 0.95...1]
            : [.writing: 0...0.95, .verifying: 0.95...1]
        self.report = report
        self.announce = announce
    }

    func begin(_ stage: FinalExportStage) {
        let started = lock.withLock {
            guard current != stage else { return false }
            current = stage
            return true
        }
        guard started else { return }
        announce?(stage)
        update(0)
    }

    /// Доля текущего прохода 0…1. Общая доля не идёт назад (поправочный проход
    /// мастеринга начинается заново) и не дёргается чаще, чем на 0,1 %.
    func update(_ fraction: Double) {
        let value: Double? = lock.withLock {
            guard let current, let span = spans[current] else { return nil }
            let overall = span.lowerBound + (span.upperBound - span.lowerBound) * min(max(fraction, 0), 1)
            guard overall >= reported + 0.001 || (overall == 1 && reported < 1) else { return nil }
            reported = overall
            return overall
        }
        if let value { report(value) }
    }
}

/// Речь обычного проекта для экспорта: .srt рядом с видео и приглушение музыки
/// под голосом строятся из одних и тех же слов ленты.
struct ExportSpeech: Sendable {
    static let noTranscriptReason = "Нет расшифровки — субтитры не созданы"
    static let noModelReason = "Нет модели распознавания — субтитры не созданы"
    static let transcriptionFailedReason = "Не получилось распознать речь — субтитры не созданы"

    /// Слова во времени ленты; nil — расшифровки нет.
    let words: [MappedTranscriptWord]?
    /// Почему субтитров нет; только когда нет слов.
    let skippedReason: String?

    init(clips: [Clip], words: [TranscriptWord]?, missingReason: String = Self.noTranscriptReason) {
        self.words = words.map { TranscriptTimelineMapper.make(clips: clips, transcripts: $0).words }
        skippedReason = words == nil ? missingReason : nil
    }

    /// Участки речи для приглушения музыки; nil — неизвестно, где речь.
    var speechRanges: [TimelineRange]? {
        words?.map { TimelineRange(from: $0.timelineStart, to: $0.timelineEnd) }
    }

    /// Фразы горизонтального ролика для .srt; nil — расшифровки нет.
    var horizontalCues: [ShortsSubtitleCue]? {
        words.map { ShortsSubtitleCueBuilder.make(mapped: $0, rules: .horizontal) }
    }

    /// Слова из кэша расшифровки. Если их нет, расшифровывает сейчас — но только
    /// уже скачанной моделью: полгигабайта молча не качаются никогда.
    /// `transcribing` — доля расшифровки 0…1, nil — доля неизвестна.
    static func load(
        clips: [Clip], store: TranscriptStore, glossaryURL: URL,
        transcribing: (@Sendable (Double?) -> Void)? = nil
    ) async throws -> ExportSpeech {
        let sources = uniqueMediaSources(in: clips)
        if let words = try? await store.correctedCachedWords(for: sources, glossaryURL: glossaryURL) {
            return ExportSpeech(clips: clips, words: words)
        }
        guard await store.modelIsCached() else {
            return ExportSpeech(clips: clips, words: nil, missingReason: noModelReason)
        }
        transcribing?(nil)
        do {
            for (index, source) in sources.enumerated() {
                _ = try await store.ensure(source: source) { fraction in
                    transcribing?(fraction.map { (Double(index) + $0) / Double(sources.count) })
                }
            }
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            Logger.export.error("Расшифровка для субтитров не удалась: \(String(reflecting: error), privacy: .public)")
            return ExportSpeech(clips: clips, words: nil, missingReason: transcriptionFailedReason)
        }
        let words = try? await store.correctedCachedWords(for: sources, glossaryURL: glossaryURL)
        return ExportSpeech(clips: clips, words: words, missingReason: transcriptionFailedReason)
    }
}
