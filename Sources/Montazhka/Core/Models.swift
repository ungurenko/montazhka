import Foundation

/// Удерживает доступ к security-scoped URL ровно на время работы с медиа.
public final class MediaAccessLease {
    public let url: URL
    private let usesSecurityScope: Bool

    public init?(reference: MediaReference) {
        guard let resolved = reference.resolvedBookmarkURL ?? reference.existingPathURL else {
            return nil
        }
        url = resolved
        usesSecurityScope = reference.bookmarkData != nil && resolved.startAccessingSecurityScopedResource()
    }

    deinit {
        if usesSecurityScope { url.stopAccessingSecurityScopedResource() }
    }
}

public struct MediaReference: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var lastKnownPath: String
    public var displayName: String
    public var bookmarkData: Data?

    public init(path: String, id: UUID = UUID(), bookmarkData: Data? = nil) {
        self.id = id
        lastKnownPath = path
        displayName = URL(fileURLWithPath: path).lastPathComponent
        self.bookmarkData = bookmarkData
    }

    public init(url: URL, id: UUID = UUID()) {
        self.id = id
        lastKnownPath = url.path
        displayName = url.lastPathComponent
        bookmarkData = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil)
    }

    public var resolvedURL: URL? {
        resolvedBookmarkURL ?? existingPathURL
    }

    public func makeAccessLease() -> MediaAccessLease? {
        MediaAccessLease(reference: self)
    }

    fileprivate var existingPathURL: URL? {
        guard FileManager.default.fileExists(atPath: lastKnownPath) else { return nil }
        return URL(fileURLWithPath: lastKnownPath)
    }

    fileprivate var resolvedBookmarkURL: URL? {
        guard let bookmarkData else { return nil }
        var stale = false
        guard
            let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale),
            FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    public mutating func relink(to url: URL) {
        self = MediaReference(url: url, id: id)
    }
}

public struct Clip: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var source: MediaReference
    public var start: Double
    public var end: Double

    public var duration: Double { max(0, end - start) }
    public var sourcePath: String {
        get { source.resolvedURL?.path ?? source.lastKnownPath }
        set { source = MediaReference(path: newValue, id: source.id) }
    }
    public var url: URL { source.resolvedURL ?? URL(fileURLWithPath: source.lastKnownPath) }
    public var fileName: String { url.deletingPathExtension().lastPathComponent }

    public init(id: UUID = UUID(), source: MediaReference, start: Double, end: Double) {
        self.id = id
        self.source = source
        self.start = start
        self.end = end
    }

    public init(id: UUID = UUID(), sourcePath: String, start: Double, end: Double) {
        self.init(id: id, source: MediaReference(path: sourcePath), start: start, end: end)
    }

    public init(id: UUID = UUID(), sourceURL: URL, start: Double, end: Double) {
        self.init(id: id, source: MediaReference(url: sourceURL), start: start, end: end)
    }

    private enum CodingKeys: String, CodingKey { case id, source, sourcePath, start, end }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        source =
            try c.decodeIfPresent(MediaReference.self, forKey: .source)
            ?? MediaReference(path: c.decode(String.self, forKey: .sourcePath))
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(source, forKey: .source)
        try c.encode(source.lastKnownPath, forKey: .sourcePath)
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end)
    }
}

public struct DetectionSettings: Codable, Equatable, Sendable {
    public var thresholdDB: Double
    public var minPauseDuration: Double
    public var paddingMS: Double

    public init(thresholdDB: Double = -40, minPauseDuration: Double = 0.8, paddingMS: Double = 150) {
        self.thresholdDB = thresholdDB
        self.minPauseDuration = minPauseDuration
        self.paddingMS = paddingMS
    }
}

public struct VoiceEnhanceSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var leveling: Double
    public var noiseReduction: Double
    public var presence: Double
    public var cacheKey: String { "v1|\(Int(leveling))|\(Int(noiseReduction))|\(Int(presence))" }

    public init(
        enabled: Bool = false, leveling: Double = 50,
        noiseReduction: Double = 50, presence: Double = 50
    ) {
        self.enabled = enabled
        self.leveling = leveling
        self.noiseReduction = noiseReduction
        self.presence = presence
    }
}

public struct MusicSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var trackID: String?
    public var customMedia: MediaReference?
    public var customPath: String? {
        get { customMedia.map { $0.resolvedURL?.path ?? $0.lastKnownPath } }
        set { customMedia = newValue.map { MediaReference(path: $0) } }
    }
    public var volume: Double
    public var eqEnabled: Bool

    public init(
        enabled: Bool = false, trackID: String? = nil,
        customMedia: MediaReference? = nil, volume: Double = 18,
        eqEnabled: Bool = true
    ) {
        self.enabled = enabled
        self.trackID = trackID
        self.customMedia = customMedia
        self.volume = volume
        self.eqEnabled = eqEnabled
    }

    public func differsOnlyByVolume(from other: MusicSettings) -> Bool {
        var a = self
        var b = other
        a.volume = 0
        b.volume = 0
        return a == b
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, trackID, customMedia, customPath, volume, eqEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        trackID = try c.decodeIfPresent(String.self, forKey: .trackID)
        customMedia = try c.decodeIfPresent(MediaReference.self, forKey: .customMedia)
        if customMedia == nil, let path = try c.decodeIfPresent(String.self, forKey: .customPath) {
            customMedia = MediaReference(path: path)
        }
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 18
        eqEnabled = try c.decodeIfPresent(Bool.self, forKey: .eqEnabled) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encodeIfPresent(trackID, forKey: .trackID)
        try c.encodeIfPresent(customMedia, forKey: .customMedia)
        try c.encodeIfPresent(customPath, forKey: .customPath)
        try c.encode(volume, forKey: .volume)
        try c.encode(eqEnabled, forKey: .eqEnabled)
    }
}

public struct Project: Identifiable, Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var id: UUID
    public var schemaVersion: Int
    public var name: String
    public var clips: [Clip]
    public var createdAt: Date
    public var updatedAt: Date
    public var detection: DetectionSettings
    public var voiceEnhance: VoiceEnhanceSettings
    public var music: MusicSettings
    public var totalDuration: Double { clips.reduce(0) { $0 + $1.duration } }

    public init(
        id: UUID = UUID(), schemaVersion: Int = Project.currentSchemaVersion,
        name: String, clips: [Clip] = [], createdAt: Date = Date(),
        updatedAt: Date = Date(), detection: DetectionSettings = DetectionSettings(),
        voiceEnhance: VoiceEnhanceSettings = VoiceEnhanceSettings(),
        music: MusicSettings = MusicSettings()
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.name = name
        self.clips = clips
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.detection = detection
        self.voiceEnhance = voiceEnhance
        self.music = music
    }

    private enum CodingKeys: String, CodingKey {
        case id, schemaVersion, name, clips, createdAt, updatedAt, detection, voiceEnhance, music
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        guard decodedVersion <= Project.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: c,
                debugDescription:
                    "Project schema \(decodedVersion) is newer than supported schema \(Project.currentSchemaVersion)."
            )
        }
        id = try c.decode(UUID.self, forKey: .id)
        schemaVersion = Project.currentSchemaVersion
        name = try c.decode(String.self, forKey: .name)
        clips = try c.decodeIfPresent([Clip].self, forKey: .clips) ?? []
        if decodedVersion == 0 {
            var sharedSources: [String: MediaReference] = [:]
            for index in clips.indices {
                let path = clips[index].source.lastKnownPath
                if let shared = sharedSources[path] {
                    clips[index].source = shared
                } else {
                    sharedSources[path] = clips[index].source
                }
            }
        }
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        detection = try c.decodeIfPresent(DetectionSettings.self, forKey: .detection) ?? DetectionSettings()
        voiceEnhance = try c.decodeIfPresent(VoiceEnhanceSettings.self, forKey: .voiceEnhance) ?? VoiceEnhanceSettings()
        music = try c.decodeIfPresent(MusicSettings.self, forKey: .music) ?? MusicSettings()
    }
}

public struct ProjectMeta: Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let updatedAt: Date
    public let duration: Double
    public let clipCount: Int

    public init(id: UUID, name: String, updatedAt: Date, duration: Double, clipCount: Int) {
        self.id = id
        self.name = name
        self.updatedAt = updatedAt
        self.duration = duration
        self.clipCount = clipCount
    }
}
