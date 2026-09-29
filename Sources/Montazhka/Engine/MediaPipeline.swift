@preconcurrency import AVFoundation
import Foundation
import OSLog

enum MediaRenderMode: Sendable {
    case preview
    case export
}

struct MediaRenderRequest: Sendable {
    let project: Project
    let mode: MediaRenderMode
    let readyEnhancedAudio: [String: URL]
    /// Участки речи на ленте — для приглушения музыки, если оно включено.
    /// nil — расшифровки нет, где речь, неизвестно.
    var speechRanges: [TimelineRange]? = nil
    /// Сколько копий видеодорожки собрать (раскладке «экран + лицо» нужны две).
    var videoCopies = 1
    /// Субтитры, впечатанные в кадр обычного проекта; nil — без них.
    var subtitleLayer: ProjectSubtitleLayer? = nil
}

struct MediaRenderResult: @unchecked Sendable {
    let composition: AVComposition
    let audioMix: AVAudioMix?
    let warnings: [CompositionWarning]
    /// Своя картинка обычного проекта (анимации, субтитры); nil — как есть.
    var videoPlan: ProjectVideoPlan? = nil
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
        // Готовый голос удерживается, пока жива склейка: уборка кэша (и в другом процессе)
        // не удалит файл из-под предпросмотра или идущего экспорта. Не удержался — файл
        // успели убрать: звук берётся из исходника.
        var leases: [CacheFileLease] = []
        for (path, url) in enhanced {
            if let lease = CacheFileLease(url: url) { leases.append(lease) } else { enhanced[path] = nil }
        }

        var music = await resolveMusic(settings: request.project.music, warnings: &warnings)
        if request.project.music.ducking, music != nil {
            if let speech = request.speechRanges {
                music?.speech = speech
            } else {
                warnings.append(.musicNotDucked)
            }
        }
        // Анимации и вшитые субтитры — только у обычного проекта: картинку черновика
        // шортса собирает ShortsRenderer.
        let isNormal = request.project.shorts == nil
        let built = await CompositionBuilder.buildResult(
            clips: request.project.clips,
            enhancedAudio: request.project.voiceEnhance.enabled ? enhanced : [:],
            music: music,
            videoCopies: request.videoCopies,
            overlays: isNormal ? availableOverlays(request.project, warnings: &warnings) : [],
            freezeTailSeconds: isNormal ? request.project.export.freezeTailSeconds : 0
        )
        warnings.append(contentsOf: built.warnings)
        CacheFileLease.attach(leases, to: built.composition)
        let subtitles = isNormal ? request.subtitleLayer : nil
        // Разные повороты и размеры исходников собираются по кускам (кроме черновика шортса:
        // его вертикальный кадр строит ShortsRenderer).
        // Явная кадровая композиция заставляет reader выдавать кадры с обычной частотой
        // и в растянутом хвосте; один растянутый sample writer заканчивает слишком рано.
        let segments =
            isNormal && (built.hasMixedGeometry || request.project.export.freezeTailSeconds > 0)
            ? built.baseSegments : []
        var videoPlan: ProjectVideoPlan?
        if !built.overlayTracks.isEmpty || subtitles != nil || !segments.isEmpty {
            do {
                videoPlan = try await ProjectVideoComposition.make(
                    composition: built.composition, baseTrackID: built.baseVideoTrackID,
                    overlays: built.overlayTracks, subtitles: subtitles, segments: segments)
            } catch {
                Logger.export.error("Картинка проекта не собралась: \(String(reflecting: error), privacy: .public)")
                warnings.append(.pictureFailed)
            }
        }
        return MediaRenderResult(
            composition: built.composition,
            audioMix: built.audioMix,
            warnings: warnings,
            videoPlan: videoPlan)
    }

    /// Картинка обычного проекта для кадров агента — такая же, как в готовом MP4:
    /// склейка, анимации и (если `project.export.burnSubtitles`) субтитры по словам
    /// ленты картинкой поверх кадра. Звук кадрам не нужен: музыка не собирается.
    nonisolated func framePlan(
        for project: Project, words: [MappedTranscriptWord]?
    ) async throws -> (
        asset: AVAsset, videoComposition: AVVideoComposition?, overlayAt: ((Double) -> CGImage?)?
    ) {
        var picture = project
        picture.music.enabled = false
        let cues = words.map { ShortsSubtitleCueBuilder.make(mapped: $0, rules: .horizontal) }
        let result = await render(
            MediaRenderRequest(
                project: picture, mode: .preview, readyEnhancedAudio: [:],
                subtitleLayer: project.export.burnSubtitles ? ProjectSubtitleLayer.saved(cues: cues) : nil))
        try Task.checkCancellation()
        return (result.composition, result.videoPlan?.frameComposition, result.videoPlan?.overlayImageAt)
    }

    /// Видимые анимации, чьи файлы на месте; пропавшие — предупреждение.
    private func availableOverlays(_ project: Project, warnings: inout [CompositionWarning]) -> [ResolvedOverlay] {
        OverlayTimeline.resolve(project.overlays, clips: project.clips).filter { resolved in
            guard resolved.status == .visible else { return false }
            guard let url = resolved.overlay.media.resolvedURL, FileManager.default.fileExists(atPath: url.path)
            else {
                warnings.append(.overlayUnavailable(resolved.overlay.media.displayName))
                return false
            }
            return true
        }
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
