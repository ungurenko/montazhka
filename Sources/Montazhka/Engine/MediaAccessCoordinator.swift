import Foundation

/// Держит security-scoped доступ ко всем исходникам открытого экрана.
@MainActor
final class MediaAccessCoordinator {
    private struct Access {
        let reference: MediaReference
        let lease: MediaAccessLease
    }

    private var accessBySourceID: [UUID: Access] = [:]

    func synchronize(_ sources: [MediaReference]) {
        let currentIDs = Set(sources.map(\.id))
        accessBySourceID = accessBySourceID.filter { currentIDs.contains($0.key) }
        for source in sources {
            guard accessBySourceID[source.id]?.reference != source else { continue }
            accessBySourceID[source.id] = source.makeAccessLease().map {
                Access(reference: source, lease: $0)
            }
        }
    }

    func url(for source: MediaReference) -> URL? {
        if let access = accessBySourceID[source.id], access.reference == source {
            return access.lease.url
        }
        return source.resolvedURL
    }

    func stopAll() {
        accessBySourceID.removeAll()
    }
}
