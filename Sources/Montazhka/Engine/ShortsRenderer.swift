@preconcurrency import AVFoundation
import CoreGraphics
import Foundation

/// Единая сборка черновика шортса: звук (голос, музыка с приглушением),
/// вертикальный кадр с лицом и наездами, хук и субтитры. Из одного плана
/// получаются и MP4, и кадры, которые видит агент, — они не расходятся.
enum ShortsRenderer {
    /// @unchecked Sendable: композиции после сборки не меняются, их только читают.
    struct Plan: @unchecked Sendable {
        let composition: AVComposition
        let audioMix: AVAudioMix?
        /// Для MP4: с запечёнными надписями.
        let exportComposition: AVMutableVideoComposition
        /// Для кадров и предпросмотра: без Core Animation, надписи — `overlay`.
        let frameComposition: AVMutableVideoComposition
        let cues: [ShortsSubtitleCue]
        let hook: ShortsHook?
        let appearance: ShortsSubtitleAppearance
        let highlight: Bool
        let warnings: [CompositionWarning]

        func overlay(at time: Double) -> CGImage? {
            guard hook != nil || !cues.isEmpty else { return nil }
            return ShortsOverlaySnapshot.image(
                at: time, renderSize: frameComposition.renderSize, cues: cues,
                appearance: appearance, highlight: highlight, hook: hook)
        }
    }

    enum RenderError: LocalizedError {
        case notAShort
        case emptyProject

        var errorDescription: String? {
            switch self {
            case .notAShort: "Это обычный проект, а не черновик шортса."
            case .emptyProject: "В черновике нет ни одного куска видео."
            }
        }
    }

    /// `words` — слова расшифровки исходников (уже с исправлениями); пусто —
    /// без субтитров и без приглушения музыки.
    static func plan(
        project: Project, words: [TranscriptWord], faces: FaceTrackStore, quality: ExportQuality,
        voiceStore: VoiceEnhanceStore? = nil, musicEQStore: MusicEQStore? = nil
    ) async throws -> Plan {
        guard let shorts = project.shorts else { throw RenderError.notAShort }
        guard let firstClip = project.clips.first else { throw RenderError.emptyProject }
        let mapped = TranscriptTimelineMapper.make(clips: project.clips, transcripts: words).words
        let layout = shorts.resolvedLayout == .auto ? ShortsDraftLayout.face : shorts.resolvedLayout

        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("montazhka-shorts-render")
        let pipeline = MediaPipeline(
            voiceStore: voiceStore ?? VoiceEnhanceStore(cacheDir: scratch),
            musicEQStore: musicEQStore ?? MusicEQStore(cacheDir: scratch))
        let rendered = await pipeline.render(
            MediaRenderRequest(
                project: project, mode: .export, readyEnhancedAudio: [:],
                speechRanges: mapped.map { TimelineRange(from: $0.timelineStart, to: $0.timelineEnd) },
                videoCopies: layout == .split ? 2 : 1))

        let display = await displaySize(of: firstClip.url)
        let canvas = ShortsFrameLayout.verticalCanvasSize(for: display, quality: quality)
        let samples = try await faceSamples(project.clips, faces: faces, needed: layout != .fit)
        let cropWidth = ShortsCameraPlanner.baseCrop(display: display, layout: .face).width / max(1, display.width)
        let paths = samples.mapValues { FaceFollowSmoother.path($0, cropWidth: cropWidth) }
        let frame = try await ShortsDraftVideoComposition.make(
            asset: rendered.composition, clips: project.clips, layout: layout,
            centre: { sourceID, time in centre(in: paths[sourceID] ?? [], at: time) },
            zooms: shorts.zooms, faceBox: FaceFollowSmoother.medianBox(samples.values.flatMap { $0 }),
            canvas: canvas)

        let hook = shorts.hook.flatMap { $0.text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        let cues =
            shorts.subtitles == nil
            ? [] : ShortsSubtitleCueBuilder.make(mapped: mapped, notBefore: hook?.duration ?? 0)
        let appearance = shorts.subtitles?.appearance ?? ShortsSubtitleSettings.saved().appearance
        let highlight = shorts.subtitles?.highlight ?? false
        guard let exportBase = frame.mutableCopy() as? AVMutableVideoComposition else {
            throw ShortsVideoCompositionError.invalidVideoTrack
        }
        let export = ShortsSubtitleRenderer.applying(
            exportBase, cues: cues, appearance: appearance,
            highlight: highlight, duration: project.totalDuration, hook: hook)
        return Plan(
            composition: rendered.composition, audioMix: rendered.audioMix, exportComposition: export,
            frameComposition: frame, cues: cues, hook: hook, appearance: appearance, highlight: highlight,
            warnings: rendered.warnings)
    }

    static func export(
        _ plan: Plan, quality: ExportQuality, to url: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await Transcoder.export(
            composed: ExportInput(
                composition: plan.composition, audioMix: plan.audioMix, videoComposition: plan.exportComposition),
            quality: quality, to: url, progress: progress)
    }

    /// Лица по кускам черновика с запасом в секунду: сглаживанию нужен разгон.
    private static func faceSamples(
        _ clips: [Clip], faces: FaceTrackStore, needed: Bool
    ) async throws -> [UUID: [FaceSample]] {
        guard needed else { return [:] }
        var result: [UUID: [FaceSample]] = [:]
        for (sourceID, group) in Dictionary(grouping: clips, by: \.source.id) {
            guard let url = group.first?.url else { continue }
            let ranges = group.map { max(0, $0.start - 1)...($0.end + 1) }
            result[sourceID] = try await faces.samples(for: url, ranges: ranges)
        }
        return result
    }

    /// Центр рамки в момент исходника: ближайшие точки пути, между ними — линейно.
    private static func centre(in path: [FacePoint], at time: Double) -> CGPoint {
        guard let first = path.first else { return CGPoint(x: 0.5, y: 0.5) }
        guard let after = path.firstIndex(where: { $0.time >= time }) else {
            return CGPoint(x: path[path.count - 1].x, y: path[path.count - 1].y)
        }
        guard after > 0 else { return CGPoint(x: first.x, y: first.y) }
        let a = path[after - 1]
        let b = path[after]
        let t = b.time > a.time ? (time - a.time) / (b.time - a.time) : 0
        return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    private static func displaySize(of url: URL) async -> CGSize {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
            let natural = try? await track.load(.naturalSize),
            let transform = try? await track.load(.preferredTransform)
        else { return CGSize(width: 1920, height: 1080) }
        let rect = CGRect(origin: .zero, size: natural).applying(transform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }
}
