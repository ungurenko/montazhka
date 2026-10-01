@preconcurrency import AVFoundation
import Foundation

struct ClipLoadResult: Sendable {
    let index: Int
    let url: URL
    let duration: Double?
    let error: String?
}

enum EditorClipLoader {
    typealias Read = @Sendable (_ index: Int, _ url: URL) async -> ClipLoadResult

    /// Чтение идёт параллельно, но порядок клипов совпадает с порядком входных URL.
    @MainActor
    static func load(urls: [URL], read: @escaping Read = EditorClipLoader.read) async -> [ClipLoadResult] {
        await withTaskGroup(of: ClipLoadResult.self) { group in
            for (index, url) in urls.enumerated() {
                group.addTask { await read(index, url) }
            }
            var results: [ClipLoadResult] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.index < $1.index }
        }
    }

    static func read(index: Int, url: URL) async -> ClipLoadResult {
        guard !Task.isCancelled else {
            return ClipLoadResult(index: index, url: url, duration: nil, error: nil)
        }
        do {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0.1 else {
                return ClipLoadResult(
                    index: index, url: url, duration: nil,
                    error: "не удалось определить длительность")
            }
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard !tracks.isEmpty else {
                return ClipLoadResult(
                    index: index, url: url, duration: nil,
                    error: "в файле нет видеодорожки")
            }
            return ClipLoadResult(index: index, url: url, duration: duration, error: nil)
        } catch {
            return ClipLoadResult(
                index: index, url: url, duration: nil,
                error: UserFacingError.make(error, context: .clipImport).what)
        }
    }
}
