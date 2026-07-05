import Foundation
import AVFoundation

/// Склеивает клипы ленты в одно видео для предпросмотра и экспорта.
enum CompositionBuilder {
    /// `enhancedAudio` — готовые файлы улучшенного звука по пути исходника:
    /// звук берётся из них (тайм-координаты совпадают), видео — из оригинала.
    static func build(clips: [Clip], enhancedAudio: [String: URL] = [:]) async -> AVMutableComposition {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return composition }

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
        return composition
    }
}
