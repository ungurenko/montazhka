@preconcurrency import AVFoundation
import Foundation

/// Фоновая музыка для склейки: файл и громкость 0…1. `speech` — участки
/// речи на ленте: под ними музыка приглушается. Пусто — ровный уровень.
struct MusicInput {
    let url: URL
    let volume: Float
    var speech: [TimelineRange] = []
}

enum CompositionWarning: Equatable {
    case missingVideo(String)
    case videoInsertFailed(String)
    case audioInsertFailed(String)
    case musicUnavailable(String)
    case musicEQFallback(String)
    case voiceFallback(String)
    /// Приглушение музыки включено, а участков речи не знаем: нет расшифровки.
    case musicNotDucked
    /// Файл анимации пропал или не читается — ролик собирается без неё.
    case overlayUnavailable(String)
    /// Анимации и вшитые субтитры не удалось наложить на кадр.
    case pictureFailed

    var message: String {
        switch self {
        case .missingVideo(let name): return "В файле «\(name)» не найдена видеодорожка."
        case .videoInsertFailed(let name): return "Не удалось вставить видео «\(name)» в монтаж."
        case .audioInsertFailed(let name): return "Не удалось вставить звук «\(name)» в монтаж."
        case .musicUnavailable(let name): return "Музыка «\(name)» недоступна — видео будет без неё."
        case .musicEQFallback(let name):
            return "Не удалось настроить музыку «\(name)» под голос — используется исходная мелодия."
        case .voiceFallback(let name): return "Не удалось обработать голос в «\(name)» — используется исходный звук."
        case .musicNotDucked: return "Музыка не приглушается под голосом: нет расшифровки"
        case .overlayUnavailable(let name): return "Анимация «\(name)» недоступна — видео будет без неё."
        case .pictureFailed: return "Не удалось наложить анимации и субтитры на кадр — видео будет без них."
        }
    }
}

/// Кусок основной видеодорожки и геометрия его исходника.
struct VideoSegmentGeometry: Equatable, Sendable {
    let timeRange: CMTimeRange
    let naturalSize: CGSize
    let preferredTransform: CGAffineTransform
}

/// @unchecked Sendable: готовая композиция после сборки не мутируется —
/// вызывающий код только читает её и передаёт дальше.
struct CompositionBuildResult: @unchecked Sendable {
    let composition: AVMutableComposition
    let audioMix: AVAudioMix?
    let warnings: [CompositionWarning]
    /// Основная видеодорожка ленты — первая видеодорожка склейки.
    var baseVideoTrackID = kCMPersistentTrackID_Invalid
    /// Дорожки анимаций поверх основной, по порядку `overlays`.
    var overlayTracks: [OverlayTrack] = []
    /// Куски основной дорожки по порядку ленты.
    var baseSegments: [VideoSegmentGeometry] = []

    /// У исходников ленты разные поворот или размер: одного поворота дорожки на всё
    /// не хватает, кадр собирается по кускам.
    var hasMixedGeometry: Bool {
        guard let first = baseSegments.first else { return false }
        return baseSegments.contains {
            $0.naturalSize != first.naturalSize || $0.preferredTransform != first.preferredTransform
        }
    }
}

/// План открытия медиа: каждый исходник и его обработанный звук загружаются один раз.
struct MediaSourceLoadPlan {
    struct Source {
        let sourceURL: URL
        let enhancedURL: URL?
        let displayName: String
    }

    let sources: [Source]
    let clipSourceIndices: [Int]
    let accessLeases: [MediaAccessLease]

    init(clips: [Clip], enhancedAudio: [String: URL]) {
        struct Key: Hashable {
            let sourcePath: String
            let enhancedPath: String?
        }

        var sourceIndices: [Key: Int] = [:]
        var plannedSources: [Source] = []
        var plannedClipIndices: [Int] = []
        var leasesBySourceID: [UUID: MediaAccessLease] = [:]

        for clip in clips {
            if leasesBySourceID[clip.source.id] == nil {
                leasesBySourceID[clip.source.id] = clip.source.makeAccessLease()
            }
            let sourceURL = (leasesBySourceID[clip.source.id]?.url ?? clip.url).standardizedFileURL
            let enhancedURL = enhancedAudio[clip.sourcePath]?.standardizedFileURL
            let key = Key(sourcePath: sourceURL.path, enhancedPath: enhancedURL?.path)
            if let existing = sourceIndices[key] {
                plannedClipIndices.append(existing)
                continue
            }
            let index = plannedSources.count
            sourceIndices[key] = index
            plannedSources.append(
                Source(
                    sourceURL: sourceURL,
                    enhancedURL: enhancedURL,
                    displayName: clip.fileName))
            plannedClipIndices.append(index)
        }

        sources = plannedSources
        clipSourceIndices = plannedClipIndices
        accessLeases = Array(leasesBySourceID.values)
    }
}

/// Склеивает клипы ленты в одно видео для предпросмотра и экспорта.
enum CompositionBuilder {
    /// `enhancedAudio` — готовые файлы улучшенного звука по пути исходника:
    /// звук берётся из них (тайм-координаты совпадают), видео — из оригинала.
    /// `music` — фоновая мелодия: повторяется по кругу на всю длину,
    /// возвращаемый `audioMix` держит её тихой и плавно гасит по краям.
    static func build(
        clips: [Clip],
        enhancedAudio: [String: URL] = [:],
        music: MusicInput? = nil
    ) async -> (composition: AVMutableComposition, audioMix: AVAudioMix?) {
        let result = await buildResult(clips: clips, enhancedAudio: enhancedAudio, music: music)
        return (result.composition, result.audioMix)
    }

    /// `videoCopies` — сколько одинаковых видеодорожек положить: раскладке
    /// «экран + лицо» нужны две, чтобы показать одну картинку в двух местах.
    /// `overlays` — видимые анимации: каждая на своей дорожке после основной
    /// (на первую видеодорожку опираются экспорт и черновики шортсов), без звука.
    static func buildResult(
        clips: [Clip],
        enhancedAudio: [String: URL] = [:],
        music: MusicInput? = nil,
        videoCopies: Int = 1,
        overlays: [ResolvedOverlay] = []
    ) async -> CompositionBuildResult {
        let composition = AVMutableComposition()
        let extraVideoTracks = (1..<max(1, videoCopies)).compactMap { _ in
            composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        }
        guard
            let videoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid),
            let audioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return CompositionBuildResult(composition: composition, audioMix: nil, warnings: []) }

        // Фаза 1 — каждый уникальный исходник открываем один раз.
        // Группы по четыре не дают большому проекту забить AVFoundation сотнями задач.
        let plan = MediaSourceLoadPlan(clips: clips, enhancedAudio: enhancedAudio)
        defer { withExtendedLifetime(plan.accessLeases) {} }
        var loadedSources = Array<LoadedSource?>(repeating: nil, count: plan.sources.count)
        for batchStart in stride(from: 0, to: plan.sources.count, by: 4) {
            guard !Task.isCancelled else { break }
            let batchEnd = min(batchStart + 4, plan.sources.count)
            let batch = await withTaskGroup(of: (Int, LoadedSource).self) { group in
                for index in batchStart..<batchEnd {
                    let source = plan.sources[index]
                    group.addTask { (index, await loadSource(source)) }
                }
                var results: [(Int, LoadedSource)] = []
                for await result in group { results.append(result) }
                return results
            }
            for (index, source) in batch { loadedSources[index] = source }
        }

        // Фаза 2 — вставка по порядку. Мутируем общие треки, поэтому строго последовательно.
        var cursor = CMTime.zero
        var transformSet = false
        var segments: [VideoSegmentGeometry] = []
        var warnings: [CompositionWarning] = []
        var voiceJoints: [(time: CMTime, leftDuration: CMTime, rightDuration: CMTime)] = []
        var previousAudioInserted = false
        var previousDuration = CMTime.zero
        for (clipIndex, clip) in clips.enumerated() {
            guard !Task.isCancelled,
                plan.clipSourceIndices.indices.contains(clipIndex),
                let source = loadedSources[plan.clipSourceIndices[clipIndex]]
            else { break }
            let rangeStart = CMTime(seconds: clip.start, preferredTimescale: 60_000)
            let rangeEnd = CMTime(seconds: clip.end, preferredTimescale: 60_000)
            let range = CMTimeRange(start: rangeStart, duration: rangeEnd - rangeStart)
            let clipStart = cursor
            if let video = source.video {
                do {
                    try videoTrack.insertTimeRange(range, of: video, at: cursor)
                    for copy in extraVideoTracks { try copy.insertTimeRange(range, of: video, at: cursor) }
                    segments.append(
                        VideoSegmentGeometry(
                            timeRange: CMTimeRange(start: cursor, duration: range.duration),
                            naturalSize: source.naturalSize ?? .zero,
                            preferredTransform: source.transform ?? .identity))
                    if !transformSet, let transform = source.transform {
                        videoTrack.preferredTransform = transform
                        for copy in extraVideoTracks { copy.preferredTransform = transform }
                        transformSet = true
                    }
                } catch {
                    warnings.append(.videoInsertFailed(source.name))
                }
            } else {
                warnings.append(.missingVideo(source.name))
            }
            var audioInserted = false
            if let enhanced = source.enhancedAudio {
                let clamped = range.intersection(enhanced.range)
                if clamped.duration.seconds > 0,
                    (try? audioTrack.insertTimeRange(clamped, of: enhanced.track, at: cursor)) != nil
                {
                    audioInserted = true
                }
            }
            if !audioInserted, let audio = source.originalAudio {
                do {
                    try audioTrack.insertTimeRange(range, of: audio, at: cursor)
                    audioInserted = true
                } catch {
                    warnings.append(.audioInsertFailed(source.name))
                }
            }
            if previousAudioInserted, audioInserted {
                voiceJoints.append(
                    (
                        time: clipStart,
                        leftDuration: previousDuration,
                        rightDuration: range.duration
                    ))
            }
            previousAudioInserted = audioInserted
            previousDuration = range.duration
            cursor = cursor + range.duration
        }
        let overlayTracks = await addOverlayTracks(overlays, to: composition, warnings: &warnings)

        var mixParameters: [AVAudioMixInputParameters] = []
        if let voice = voiceMixParameters(track: audioTrack, joints: voiceJoints) {
            mixParameters.append(voice)
        }
        if let music, cursor > .zero {
            if let musicParameters = await addMusicTrack(music, to: composition, totalDuration: cursor) {
                mixParameters.append(musicParameters)
            }
        }
        let audioMix: AVAudioMix? =
            mixParameters.isEmpty
            ? nil
            : {
                let mix = AVMutableAudioMix()
                mix.inputParameters = mixParameters
                return mix
            }()
        return CompositionBuildResult(
            composition: composition, audioMix: audioMix, warnings: warnings,
            baseVideoTrackID: videoTrack.trackID, overlayTracks: overlayTracks, baseSegments: segments)
    }

    /// Каждая видимая анимация — своя дорожка: кусок файла с `mediaStart` длиной в окно
    /// встаёт на начало окна. Окно дорожки — то, что реально вставилось: файл бывает
    /// короче, и за его концом дорожка держала бы последний кадр.
    private static func addOverlayTracks(
        _ overlays: [ResolvedOverlay], to composition: AVMutableComposition,
        warnings: inout [CompositionWarning]
    ) async -> [OverlayTrack] {
        var tracks: [OverlayTrack] = []
        for resolved in overlays where resolved.status == .visible {
            guard !Task.isCancelled else { break }
            let overlay = resolved.overlay
            let timescale: CMTimeScale = 60_000
            // Ассет держим до вставки: дорожка без живого ассета не вставляется.
            let asset = overlay.media.resolvedURL.map { AVURLAsset(url: $0) }
            defer { withExtendedLifetime(asset) {} }
            guard let asset,
                let source = try? await asset.loadTracks(withMediaType: .video).first,
                case let (range, size, transform)? = try? await source.load(
                    .timeRange, .naturalSize, .preferredTransform)
            else {
                warnings.append(.overlayUnavailable(overlay.media.displayName))
                continue
            }
            let wanted = CMTimeRange(
                start: range.start + CMTime(seconds: resolved.mediaStart, preferredTimescale: timescale),
                duration: CMTime(seconds: resolved.window.to - resolved.window.from, preferredTimescale: timescale))
            let piece = wanted.intersection(range)
            let at = CMTime(seconds: resolved.window.from, preferredTimescale: timescale)
            guard piece.duration > .zero,
                let track = composition.addMutableTrack(
                    withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            else {
                warnings.append(.overlayUnavailable(overlay.media.displayName))
                continue
            }
            do {
                try track.insertTimeRange(piece, of: source, at: at)
            } catch {
                composition.removeTrack(track)
                warnings.append(.overlayUnavailable(overlay.media.displayName))
                continue
            }
            tracks.append(
                OverlayTrack(
                    overlayID: overlay.id, trackID: track.trackID,
                    window: TimelineRange(from: resolved.window.from, to: (at + piece.duration).seconds),
                    naturalSize: size, preferredTransform: transform, position: overlay.position,
                    scale: overlay.scale))
        }
        return tracks
    }

    private static func voiceMixParameters(
        track: AVCompositionTrack,
        joints: [(time: CMTime, leftDuration: CMTime, rightDuration: CMTime)]
    ) -> AVMutableAudioMixInputParameters? {
        // По нашим замерам (AVAssetReaderAudioMixOutput, 44,1 и 48 кГц) AVAudioMix меняет громкость
        // не быстрее, чем от 1 до 0 за 25 мс: рампа короче не доходит до нуля, и на склейке
        // остаётся щелчок (8 мс гасили звук лишь до 0,6). Тест щелчка — в MediaPipelineTests.
        let fade = CMTime(seconds: 0.030, preferredTimescale: 48_000)
        let minSide = 2 * fade.seconds
        let safeJoints = joints.filter { $0.leftDuration.seconds >= minSide && $0.rightDuration.seconds >= minSide }
        guard !safeJoints.isEmpty else { return nil }
        let params = AVMutableAudioMixInputParameters(track: track)
        params.setVolume(1, at: .zero)
        for joint in safeJoints {
            params.setVolumeRamp(
                fromStartVolume: 1, toEndVolume: 0,
                timeRange: CMTimeRange(start: joint.time - fade, duration: fade))
            params.setVolumeRamp(
                fromStartVolume: 0, toEndVolume: 1,
                timeRange: CMTimeRange(start: joint.time, duration: fade))
        }
        return params
    }

    /// Готовые дорожки одного исходника переиспользуются всеми его фрагментами.
    /// @unchecked Sendable: AVFoundation-треки после загрузки не мутируются.
    private struct LoadedSource: @unchecked Sendable {
        let name: String
        let video: AVAssetTrack?
        let transform: CGAffineTransform?
        let naturalSize: CGSize?
        let enhancedAudio: (track: AVAssetTrack, range: CMTimeRange)?
        let originalAudio: AVAssetTrack?
        let sourceAsset: AVURLAsset
        let enhancedAsset: AVURLAsset?
    }

    private static func loadSource(_ source: MediaSourceLoadPlan.Source) async -> LoadedSource {
        let asset = AVURLAsset(url: source.sourceURL)
        async let videoLoad = loadVideo(from: asset)
        async let originalAudio = firstAudioTrack(of: asset)
        async let enhanced = loadEnhancedAudio(url: source.enhancedURL)

        let (video, transform, naturalSize) = await videoLoad
        let enhancedResult = await enhanced
        return LoadedSource(
            name: source.displayName, video: video, transform: transform, naturalSize: naturalSize,
            enhancedAudio: enhancedResult.map { ($0.track, $0.range) },
            originalAudio: await originalAudio,
            sourceAsset: asset,
            enhancedAsset: enhancedResult?.asset
        )
    }

    private static func loadVideo(from asset: AVURLAsset) async -> (AVAssetTrack?, CGAffineTransform?, CGSize?) {
        guard let video = try? await asset.loadTracks(withMediaType: .video).first else { return (nil, nil, nil) }
        return (video, try? await video.load(.preferredTransform), try? await video.load(.naturalSize))
    }

    private static func firstAudioTrack(of asset: AVURLAsset) async -> AVAssetTrack? {
        (try? await asset.loadTracks(withMediaType: .audio))?.first
    }

    private static func loadEnhancedAudio(url: URL?) async -> (
        track: AVAssetTrack, range: CMTimeRange, asset: AVURLAsset
    )? {
        guard let url else { return nil }
        let asset = AVURLAsset(url: url)
        guard let audio = try? await asset.loadTracks(withMediaType: .audio).first,
            let trackRange = try? await audio.load(.timeRange)
        else { return nil }
        return (audio, trackRange, asset)
    }

    /// Вставляет мелодию по кругу на всю длительность и строит микс:
    /// плавный вход в начале, тихий уровень (под речью — ещё тише), затухание в конце.
    private static func addMusicTrack(
        _ music: MusicInput,
        to composition: AVMutableComposition,
        totalDuration: CMTime
    ) async -> AVMutableAudioMixInputParameters? {
        let asset = AVURLAsset(url: music.url)
        guard let source = try? await asset.loadTracks(withMediaType: .audio).first,
            let sourceRange = try? await source.load(.timeRange),
            sourceRange.duration.seconds > 0.1,
            let musicTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return nil }

        // Луп: целые проигрыши + обрезанный хвост до конца видео.
        var cursor = CMTime.zero
        while cursor < totalDuration {
            let remaining = totalDuration - cursor
            let piece =
                remaining < sourceRange.duration
                ? CMTimeRange(start: sourceRange.start, duration: remaining)
                : sourceRange
            guard (try? musicTrack.insertTimeRange(piece, of: source, at: cursor)) != nil else { break }
            cursor = cursor + piece.duration
        }

        let points = MusicDucking.envelope(
            speech: music.speech, total: totalDuration.seconds, level: Double(max(0, min(1, music.volume))))
        let params = AVMutableAudioMixInputParameters(track: musicTrack)
        params.setVolume(Float(points.first?.volume ?? 0), at: .zero)
        for (a, b) in zip(points, points.dropFirst()) where b.time > a.time {
            params.setVolumeRamp(
                fromStartVolume: Float(a.volume), toEndVolume: Float(b.volume),
                timeRange: CMTimeRange(
                    start: CMTime(seconds: a.time, preferredTimescale: 600),
                    end: CMTime(seconds: b.time, preferredTimescale: 600)))
        }
        return params
    }
}
