import Foundation
import AVFoundation

/// Склеивает клипы ленты в одно видео для предпросмотра и экспорта.
enum CompositionBuilder {
    static func build(clips: [Clip]) async -> AVMutableComposition {
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
            if let audio = try? await asset.loadTracks(withMediaType: .audio).first {
                try? audioTrack.insertTimeRange(range, of: audio, at: cursor)
            }
            cursor = cursor + range.duration
        }
        return composition
    }
}
