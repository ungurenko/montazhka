import Foundation
import AVFoundation

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
        case .musicEQFallback(let name): return "Не удалось настроить музыку «\(name)» под голос — используется исходная мелодия."
        case .voiceFallback(let name): return "Не удалось обработать голос в «\(name)» — используется исходный звук."
        }
    }
}

struct CompositionBuildResult: @unchecked Sendable {
    let composition: AVMutableComposition
    let audioMix: AVAudioMix?
    let warnings: [CompositionWarning]
}

/// Склеивает клипы ленты в одно видео для предпросмотра и экспорта.
enum CompositionBuilder {
    /// `enhancedAudio` — готовые файлы улучшенного звука по пути исходника:
    /// звук берётся из них (тайм-координаты совпадают), видео — из оригинала.
    /// `music` — фоновая мелодия: повторяется по кругу на всю длину,
    /// возвращаемый `audioMix` держит её тихой и плавно гасит по краям.
    static func build(clips: [Clip],
                      enhancedAudio: [String: URL] = [:],
                      music: MusicInput? = nil) async -> (composition: AVMutableComposition, audioMix: AVAudioMix?) {
        let result = await buildResult(clips: clips, enhancedAudio: enhancedAudio, music: music)
        return (result.composition, result.audioMix)
    }

    static func buildResult(clips: [Clip],
                            enhancedAudio: [String: URL] = [:],
                            music: MusicInput? = nil) async -> CompositionBuildResult {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return CompositionBuildResult(composition: composition, audioMix: nil, warnings: []) }

        // Фаза 1 — открыть исходники и загрузить дорожки всех клипов параллельно.
        // Порядок восстанавливаем по индексу: вставка ниже строго упорядочена.
        let loaded = await withTaskGroup(of: (Int, LoadedClip).self) { group -> [LoadedClip] in
            for (index, clip) in clips.enumerated() {
                group.addTask { (index, await loadClip(clip, enhancedURL: enhancedAudio[clip.sourcePath])) }
            }
            var acc: [(Int, LoadedClip)] = []
            for await result in group { acc.append(result) }
            return acc.sorted { $0.0 < $1.0 }.map(\.1)
        }

        // Фаза 2 — вставка по порядку. Мутируем общие треки, поэтому строго последовательно.
        var cursor = CMTime.zero
        var transformSet = false
        var warnings: [CompositionWarning] = []
        var voiceJoints: [(time: CMTime, leftDuration: CMTime, rightDuration: CMTime)] = []
        var previousAudioInserted = false
        var previousDuration = CMTime.zero
        for clip in loaded {
            let range = clip.range
            let clipStart = cursor
            if let video = clip.video {
                do {
                    try videoTrack.insertTimeRange(range, of: video, at: cursor)
                    if !transformSet, let transform = clip.transform {
                        videoTrack.preferredTransform = transform
                        transformSet = true
                    }
                } catch {
                    warnings.append(.videoInsertFailed(clip.name))
                }
            } else {
                warnings.append(.missingVideo(clip.name))
            }
            var audioInserted = false
            if let enhanced = clip.enhancedAudio,
               (try? audioTrack.insertTimeRange(enhanced.range, of: enhanced.track, at: cursor)) != nil {
                audioInserted = true
            }
            if !audioInserted, let audio = clip.originalAudio {
                do {
                    try audioTrack.insertTimeRange(range, of: audio, at: cursor)
                    audioInserted = true
                } catch {
                    warnings.append(.audioInsertFailed(clip.name))
                }
            }
            if previousAudioInserted, audioInserted {
                voiceJoints.append((time: clipStart,
                                    leftDuration: previousDuration,
                                    rightDuration: range.duration))
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
        let audioMix: AVAudioMix? = mixParameters.isEmpty ? nil : {
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
            params.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0,
                                 timeRange: CMTimeRange(start: joint.time - fade, duration: fade))
            params.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1,
                                 timeRange: CMTimeRange(start: joint.time, duration: fade))
        }
        return params
    }

    /// Готовые дорожки одного клипа — грузятся заранее и параллельно, вставляются по порядку.
    private struct LoadedClip {
        let name: String
        let range: CMTimeRange
        let video: AVAssetTrack?
        let transform: CGAffineTransform?
        /// Улучшенный звук с уже обрезанным по клипу диапазоном (если есть).
        let enhancedAudio: (track: AVAssetTrack, range: CMTimeRange)?
        /// Запасная оригинальная дорожка — если улучшенной нет или её вставка не удалась.
        let originalAudio: AVAssetTrack?
        /// Держим исходники живыми до вставки: AVAssetTrack не удерживает свой asset,
        /// а без живого asset вставка молча даёт пустой трек.
        let sourceAsset: AVURLAsset
        let enhancedAsset: AVURLAsset?
    }

    /// Открывает исходник и грузит видео, оригинальный и улучшенный звук параллельно.
    private static func loadClip(_ clip: Clip, enhancedURL: URL?) async -> LoadedClip {
        let asset = AVURLAsset(url: clip.url)
        let range = CMTimeRange(
            start: CMTime(seconds: clip.start, preferredTimescale: 600),
            duration: CMTime(seconds: clip.duration, preferredTimescale: 600)
        )
        async let videoLoad = loadVideo(from: asset)
        async let originalAudio = firstAudioTrack(of: asset)
        async let enhanced = loadEnhancedAudio(url: enhancedURL, clipRange: range)

        let (video, transform) = await videoLoad
        let enhancedResult = await enhanced
        return LoadedClip(
            name: clip.fileName, range: range, video: video, transform: transform,
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

    private static func loadEnhancedAudio(url: URL?, clipRange: CMTimeRange) async -> (track: AVAssetTrack, range: CMTimeRange, asset: AVURLAsset)? {
        guard let url else { return nil }
        let asset = AVURLAsset(url: url)
        guard let audio = try? await asset.loadTracks(withMediaType: .audio).first,
              let trackRange = try? await audio.load(.timeRange) else { return nil }
        // Декодер мог дать ±пару мс на хвосте — обрезаем, иначе вставка молча падает.
        let clamped = clipRange.intersection(trackRange)
        guard clamped.duration.seconds > 0 else { return nil }
        return (audio, clamped, asset)
    }

    /// Вставляет мелодию по кругу на всю длительность и строит микс:
    /// плавный вход в начале, ровный тихий уровень, затухание в конце.
    private static func addMusicTrack(_ music: MusicInput,
                                      to composition: AVMutableComposition,
                                      totalDuration: CMTime) async -> AVMutableAudioMixInputParameters? {
        let asset = AVURLAsset(url: music.url)
        guard let source = try? await asset.loadTracks(withMediaType: .audio).first,
              let sourceRange = try? await source.load(.timeRange),
              sourceRange.duration.seconds > 0.1,
              let musicTrack = composition.addMutableTrack(withMediaType: .audio,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return nil }

        // Луп: целые проигрыши + обрезанный хвост до конца видео.
        var cursor = CMTime.zero
        while cursor < totalDuration {
            let remaining = totalDuration - cursor
            let piece = remaining < sourceRange.duration
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
        params.setVolumeRamp(fromStartVolume: 0, toEndVolume: level,
                             timeRange: CMTimeRange(start: .zero,
                                                    duration: CMTime(seconds: fadeIn, preferredTimescale: 600)))
        params.setVolume(level, at: CMTime(seconds: fadeIn, preferredTimescale: 600))
        params.setVolumeRamp(fromStartVolume: level, toEndVolume: 0,
                             timeRange: CMTimeRange(start: CMTime(seconds: total - fadeOut, preferredTimescale: 600),
                                                    duration: CMTime(seconds: fadeOut, preferredTimescale: 600)))
        return params
    }
}
