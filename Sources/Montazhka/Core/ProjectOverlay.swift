import Foundation

/// Где держится анимация: момент исходника (как у наезда шортса), поэтому
/// правки ленты её не сдвигают — она едет вместе со своим словом.
struct OverlayAnchor: Codable, Equatable, Sendable {
    var sourceID: UUID
    var sourceTime: Double
    /// Слово, к которому привязали, — чтобы агент узнал место.
    var wordText: String?
}

/// Чем анимация встаёт на якорь: началом или своим главным моментом.
enum OverlayAlign: String, Codable, Sendable {
    case start, payoff
}

/// Где анимация в кадре.
enum OverlayPosition: String, Codable, Sendable {
    case full, center, topLeft, topRight, bottomLeft, bottomRight
}

/// Анимация поверх видео (прозрачный ролик, например из HyperFrames).
public struct ProjectOverlay: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    var media: MediaReference
    var anchor: OverlayAnchor
    var align: OverlayAlign
    /// Секунда анимации, которая совпадает с якорем при `payoff`.
    var payoffAt: Double
    var duration: Double
    var position: OverlayPosition
    var scale: Double
}
