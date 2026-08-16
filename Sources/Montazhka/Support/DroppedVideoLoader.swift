import Foundation
import UniformTypeIdentifiers

enum DroppedVideoLoader {
    private static let videoExtensions = Set(["mp4", "mov", "m4v", "mpg", "mpeg", "avi", "mkv"])

    /// File URL загружаются последовательно: порядок на ленте совпадает с порядком drop.
    @MainActor
    static func load(from providers: [NSItemProvider]) async -> [URL] {
        var result: [URL] = []
        for provider in providers
        where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            guard !Task.isCancelled, let url = await loadURL(from: provider) else { continue }
            if videoExtensions.contains(url.pathExtension.lowercased()) { result.append(url) }
        }
        return result
    }

    @MainActor
    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                if let data = item as? Data {
                    continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
                } else if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let url = item as? NSURL {
                    continuation.resume(returning: url as URL)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
