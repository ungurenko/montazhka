@preconcurrency import AVFoundation
import Foundation

/// Фоновая музыка для склейки: файл и громкость 0…1.
struct MusicInput {
    let url: URL
    let volume: Float
}

enum CompositionWarning: Equatable {
    case missingVideo(String)
    case videoInsertFailed(String)
    case audioInsertFailed(String)
    case musicUnavailable(String)
    case musicEQFallback(String)
    case voiceFallback(String)

    var message: String {
        switch self {
        case .missingVideo(let name): return "В файле «\(name)» не найдена видеодорожка."
        case .videoInsertFailed(let name): return "Не удалось вставить видео «\(name)» в монтаж."
        case .audioInsertFailed(let name): return "Не удалось вставить звук «\(name)» в монтаж."
        case .musicUnavailable(let name): return "Музыка «\(name)» недоступна — видео будет без неё."
        case .musicEQFallback(let name):
            return "Не удалось настроить музыку «\(name)» под голос — используется исходная мелодия."
        case .voiceFallback(let name): return "Не удалось обработать голос в «\(name)» — используется исходный звук."
        }
    }
}

/// @unchecked Sendable: готовая композиция после сборки не мутируется —
/// вызывающий код только читает её и передаёт дальше.
struct CompositionBuildResult: @unchecked Sendable {
    let composition: AVMutableComposition
    let audioMix: AVAudioMix?
    let warnings: [CompositionWarning]
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

    static func buildResult(
        clips: [Clip],
        enhancedAudio: [String: URL] = [:],
        music: MusicInput? = nil
    ) async -> CompositionBuildResult {
        let composition = AVMutableComposition()
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
                    if !transformSet, let transform = source.transform {
                        videoTrack.preferredTransform = transform
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
        return CompositionBuildResult(composition: composition, audioMix: audioMix, warnings: warnings)
    }

    private static func voiceMixParameters(
        track: AVCompositionTrack,
        joints: [(time: CMTime, leftDuration: CMTime, rightDuration: CMTime)]
    ) -> AVMutableAudioMixInputParameters? {
        let fade = CMTime(seconds: 0.008, preferredTimescale: 48_000)
        let safeJoints = joints.filter { $0.leftDuration.seconds >= 0.016 && $0.rightDuration.seconds >= 0.016 }
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

        let (video, transform) = await videoLoad
        let enhancedResult = await enhanced
        return LoadedSource(
            name: source.displayName, video: video, transform: transform,
            enhancedAudio: enhancedResult.map { ($0.track, $0.range) },
            originalAudio: await originalAudio,
            sourceAsset: asset,
            enhancedAsset: enhancedResult?.asset
        )
    }

    private static func loadVideo(from asset: AVURLAsset) async -> (AVAssetTrack?, CGAffineTransform?) {
        guard let video = try? await asset.loadTracks(withMediaType: .video).first else { return (nil, nil) }
        return (video, try? await video.load(.preferredTransform))
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
    /// плавный вход в начале, ровный тихий уровень, затухание в конце.
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

        let total = totalDuration.seconds
        let level = max(0, min(1, music.volume))
        let fadeIn = min(1.0, total / 4)
        let fadeOut = min(3.0, total / 3)
        let params = AVMutableAudioMixInputParameters(track: musicTrack)
        params.setVolumeRamp(
            fromStartVolume: 0, toEndVolume: level,
            timeRange: CMTimeRange(
                start: .zero,
                duration: CMTime(seconds: fadeIn, preferredTimescale: 600)))
        params.setVolume(level, at: CMTime(seconds: fadeIn, preferredTimescale: 600))
        params.setVolumeRamp(
            fromStartVolume: level, toEndVolume: 0,
            timeRange: CMTimeRange(
                start: CMTime(seconds: total - fadeOut, preferredTimescale: 600),
                duration: CMTime(seconds: fadeOut, preferredTimescale: 600)))
        return params
    }
}
