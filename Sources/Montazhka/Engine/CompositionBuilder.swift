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

        var cursor = CMTime.zero
        var transformSet = false
        for clip in clips {
            let asset = AVURLAsset(url: clip.url)
            let range = CMTimeRange(
                start: CMTime(seconds: clip.start, preferredTimescale: 600),
                duration: CMTime(seconds: clip.duration, preferredTimescale: 600)
            )
            if let video = try? await asset.loadTracks(withMediaType: .video).first {
                try? videoTrack.insertTimeRange(range, of: video, at: cursor)
                if !transformSet, let transform = try? await video.load(.preferredTransform) {
                    videoTrack.preferredTransform = transform
                    transformSet = true
                }
            }
            var audioInserted = false
            if let enhancedURL = enhancedAudio[clip.sourcePath] {
                let enhancedAsset = AVURLAsset(url: enhancedURL)
                if let audio = try? await enhancedAsset.loadTracks(withMediaType: .audio).first,
                   let trackRange = try? await audio.load(.timeRange) {
                    // Декодер мог дать ±пару мс на хвосте — обрезаем, иначе вставка молча падает.
                    let clamped = range.intersection(trackRange)
                    if clamped.duration.seconds > 0,
                       (try? audioTrack.insertTimeRange(clamped, of: audio, at: cursor)) != nil {
                        audioInserted = true
                    }
                }
            }
            if !audioInserted, let audio = try? await asset.loadTracks(withMediaType: .audio).first {
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
