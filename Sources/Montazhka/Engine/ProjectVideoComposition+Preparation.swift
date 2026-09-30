@preconcurrency import AVFoundation
import Foundation
import OSLog

/// Эксперимент включается только после матрицы качества и парных замеров.
/// nil оставляет прежний экспорт и служит контрольным путём.
enum ExportRenderResolutionPolicy {
    static let isEnabled = false

    static func requestedQuality(_ quality: ExportQuality) -> ExportQuality? {
        isEnabled ? quality : nil
    }
}

extension ProjectVideoComposition {
    /// Обычный проект владеет своей картинкой; вертикальную собирает ShortsRenderer.
    /// Неудачная подготовка экспериментального размера возвращает прежний план.
    static func prepare(_ built: CompositionBuildResult, for request: MediaRenderRequest) async throws
        -> ProjectVideoPlan?
    {
        guard request.project.shorts == nil else { return nil }
        try Task.checkCancellation()
        // Своя геометрия сохраняет повороты разных исходников и частоту кадров замороженного хвоста.
        let segments = built.hasMixedGeometry || request.project.export.freezeTailSeconds > 0 ? built.baseSegments : []
        if request.mode == .export, let quality = request.exportQuality {
            do {
                let input = ExportInput(composition: built.composition, audioMix: built.audioMix)
                let settings = try await Transcoder.settings(for: quality, input: input)
                if let video = try await built.composition.loadTrack(withTrackID: built.baseVideoTrackID) {
                    let (natural, transform) = try await video.load(.naturalSize, .preferredTransform)
                    let rect = CGRect(origin: .zero, size: natural).applying(transform)
                    if settings.dimensions.width < abs(rect.width), settings.dimensions.height < abs(rect.height) {
                        try Task.checkCancellation()
                        return try await make(
                            composition: built.composition, baseTrackID: built.baseVideoTrackID,
                            overlays: built.overlayTracks, subtitles: request.subtitleLayer, segments: segments,
                            freezeAt: built.freezeAt?.seconds, targetRenderSize: settings.dimensions)
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Только подготовка картинки. Ошибки записи и защиты выходного файла обрабатываются отдельно.
                Logger.export.info(
                    "Экспериментальный кадр не подготовлен: \(String(reflecting: error), privacy: .public)")
            }
        }
        try Task.checkCancellation()
        return try await make(
            composition: built.composition, baseTrackID: built.baseVideoTrackID,
            overlays: built.overlayTracks, subtitles: request.subtitleLayer, segments: segments,
            freezeAt: built.freezeAt?.seconds)
    }
}
