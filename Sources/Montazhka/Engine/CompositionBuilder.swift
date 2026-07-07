import Foundation
import AVFoundation

/// Фоновая музыка для склейки: файл и громкость 0…1.
struct MusicInput {
    let url: URL
    let volume: Float
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
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return (composition, nil) }

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
        for clip in loaded {
            let range = clip.range
            if let video = clip.video {
                try? videoTrack.insertTimeRange(range, of: video, at: cursor)
                if !transformSet, let transform = clip.transform {
                    videoTrack.preferredTransform = transform
                    transformSet = true
                }
            }
            var audioInserted = false
            if let enhanced = clip.enhancedAudio,
               (try? audioTrack.insertTimeRange(enhanced.range, of: enhanced.track, at: cursor)) != nil {
                audioInserted = true
            }
            if !audioInserted, let audio = clip.originalAudio {
                try? audioTrack.insertTimeRange(range, of: audio, at: cursor)
            }
            cursor = cursor + range.duration
        }

        var audioMix: AVAudioMix?
        if let music, cursor > .zero {
            audioMix = await addMusicTrack(music, to: composition, totalDuration: cursor)
        }
        return (composition, audioMix)
    }

    /// Готовые дорожки одного клипа — грузятся заранее и параллельно, вставляются по порядку.
    private struct LoadedClip {
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
            range: range, video: video, transform: transform,
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
                                      totalDuration: CMTime) async -> AVAudioMix? {
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
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix
    }
}
