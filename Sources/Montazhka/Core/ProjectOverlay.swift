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

enum OverlayMode: String, Codable, Sendable {
    case transparent, cover
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
    /// Непрозрачный слой разрешён только при явном cover.
    var mode: OverlayMode = .transparent

    private enum CodingKeys: String, CodingKey {
        case id, media, anchor, align, payoffAt, duration, position, scale, mode
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(media, forKey: .media)
        try c.encode(anchor, forKey: .anchor); try c.encode(align, forKey: .align)
        try c.encode(payoffAt, forKey: .payoffAt); try c.encode(duration, forKey: .duration)
        try c.encode(position, forKey: .position); try c.encode(scale, forKey: .scale)
        if mode != .transparent { try c.encode(mode, forKey: .mode) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        media = try c.decode(MediaReference.self, forKey: .media)
        anchor = try c.decode(OverlayAnchor.self, forKey: .anchor)
        align = try c.decode(OverlayAlign.self, forKey: .align)
        payoffAt = try c.decode(Double.self, forKey: .payoffAt)
        duration = try c.decode(Double.self, forKey: .duration)
        position = try c.decode(OverlayPosition.self, forKey: .position)
        scale = try c.decode(Double.self, forKey: .scale)
        mode = try c.decodeIfPresent(OverlayMode.self, forKey: .mode) ?? .transparent
    }

    init(
        id: UUID, media: MediaReference, anchor: OverlayAnchor, align: OverlayAlign, payoffAt: Double,
        duration: Double, position: OverlayPosition, scale: Double, mode: OverlayMode = .transparent
    ) {
        self.id = id; self.media = media; self.anchor = anchor; self.align = align; self.payoffAt = payoffAt
        self.duration = duration; self.position = position; self.scale = scale; self.mode = mode
    }
}
