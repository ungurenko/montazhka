import AVFoundation
import Foundation

enum MediaRenderMode: Sendable {
    case preview
    case export
}

struct MediaRenderRequest: Sendable {
    let project: Project
    let mode: MediaRenderMode
    let readyEnhancedAudio: [String: URL]
}

struct MediaRenderResult: @unchecked Sendable {
    let composition: AVComposition
    let audioMix: AVAudioMix?
    let warnings: [CompositionWarning]
}

/// Единая точка сборки предпросмотра и экспорта.
/// Последовательность и отмена тяжёлых работ изолированы от UI-актора.
actor MediaPipeline {
    private let voiceStore: VoiceEnhanceStore
    private let musicEQStore: MusicEQStore

    init(voiceStore: VoiceEnhanceStore, musicEQStore: MusicEQStore) {
        self.voiceStore = voiceStore
        self.musicEQStore = musicEQStore
    }

    func render(_ request: MediaRenderRequest) async -> MediaRenderResult {
        var warnings: [CompositionWarning] = []
        var enhanced = request.mode == .preview ? request.readyEnhancedAudio : [:]

        if request.mode == .export, request.project.voiceEnhance.enabled {
            for source in uniqueSources(request.project.clips) {
                guard !Task.isCancelled else { break }
                do {
                    let path = source.resolvedURL?.path ?? source.lastKnownPath
                    enhanced[path] = try await voiceStore.ensure(
                        source: path,
                        settings: request.project.voiceEnhance
                    )
                } catch VoiceEnhanceError.noAudioTrack {
                    continue
                } catch {
                    warnings.append(.voiceFallback(source.displayName))
                }
            }
        }

        let music = await resolveMusic(settings: request.project.music, warnings: &warnings)
        let built = await CompositionBuilder.buildResult(
            clips: request.project.clips,
            enhancedAudio: request.project.voiceEnhance.enabled ? enhanced : [:],
            music: music
        )
        warnings.append(contentsOf: built.warnings)
        return MediaRenderResult(
            composition: built.composition,
            audioMix: built.audioMix,
            warnings: warnings)
    }

    private func uniqueSources(_ clips: [Clip]) -> [MediaReference] {
        var seen = Set<UUID>()
        return clips.compactMap { seen.insert($0.source.id).inserted ? $0.source : nil }
    }

    private func resolveMusic(
        settings: MusicSettings,
        warnings: inout [CompositionWarning]
    ) async -> MusicInput? {
        guard settings.enabled else { return nil }
        let url: URL?
        let name: String
        if let custom = settings.customMedia {
            url = custom.resolvedURL
            name = custom.displayName
        } else if let id = settings.trackID, let track = MusicLibrary.track(id: id) {
            url = track.url
            name = track.title
        } else {
            url = nil
            name = "выбранная мелодия"
        }
        guard let url else {
            warnings.append(.musicUnavailable(name))
            return nil
        }
        if settings.eqEnabled {
            do {
                let processed = try await musicEQStore.ensure(source: url.path)
                return MusicInput(url: processed, volume: Float(settings.volume / 100))
            } catch {
                warnings.append(.musicEQFallback(name))
            }
        }
        return MusicInput(url: url, volume: Float(settings.volume / 100))
    }
}
