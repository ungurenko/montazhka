@preconcurrency import AVFoundation
import CoreGraphics
import Foundation

/// Видеотрек одной анимации поверх основной картинки.
/// @unchecked Sendable: только значения, после сборки не меняются.
struct OverlayTrack: @unchecked Sendable {
    let overlayID: UUID
    let trackID: CMPersistentTrackID
    /// Когда анимация видна на ленте.
    let window: TimelineRange
    let naturalSize: CGSize
    let preferredTransform: CGAffineTransform
    let position: OverlayPosition
    let scale: Double
}

/// Субтитры, впечатанные в кадр обычного проекта.
struct ProjectSubtitleLayer: Sendable {
    let cues: [ShortsSubtitleCue]
    let appearance: ShortsSubtitleAppearance
    let highlight: Bool
}

/// Картинка обычного проекта с анимациями и субтитрами.
/// @unchecked Sendable: композиции после сборки не меняются, их только читают.
struct ProjectVideoPlan: @unchecked Sendable {
    /// Основа и анимации: предпросмотр и кадры агента.
    let frameComposition: AVMutableVideoComposition
    /// То же и субтитры слоем Core Animation поверх всего — для MP4.
    let exportComposition: AVMutableVideoComposition
    /// Субтитры картинкой для кадров агента.
    let overlayImageAt: (@Sendable (Double) -> CGImage?)?
}

enum ProjectVideoComposition {
    enum BuildError: LocalizedError {
        case notImplemented

        var errorDescription: String? {
            "Анимации и вшитые субтитры в обычном проекте пока не собираются."
        }
    }

    /// nil, когда нет ни анимаций, ни вшитых субтитров: экспорт и предпросмотр — как раньше.
    static func make(
        composition: AVComposition, baseTrackID: CMPersistentTrackID, overlays: [OverlayTrack],
        subtitles: ProjectSubtitleLayer?, duration: Double
    ) async throws -> ProjectVideoPlan? {
        guard overlays.isEmpty, subtitles == nil else { throw BuildError.notImplemented }
        return nil
    }
}
