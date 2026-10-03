@preconcurrency import AVFoundation
import Foundation

extension ProjectVideoComposition {
    /// Обычный проект владеет своей картинкой; вертикальную собирает ShortsRenderer.
    static func prepare(_ built: CompositionBuildResult, for request: MediaRenderRequest) async throws
        -> ProjectVideoPlan?
    {
        guard request.project.shorts == nil else { return nil }
        try Task.checkCancellation()
        // Своя геометрия сохраняет повороты разных исходников и частоту кадров замороженного хвоста.
        let segments = built.hasMixedGeometry || request.project.export.freezeTailSeconds > 0 ? built.baseSegments : []
        return try await make(
            composition: built.composition, baseTrackID: built.baseVideoTrackID,
            overlays: built.overlayTracks, subtitles: request.subtitleLayer, segments: segments,
            freezeAt: built.freezeAt?.seconds)
    }
}
