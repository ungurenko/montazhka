import Foundation

/// Держит security-scoped доступ ко всем исходникам открытого экрана.
///
/// Резолв lease (распаковка bookmark, проверки существования) выполняется
/// вне главного потока: `synchronize` мгновенно обновляет только bookkeeping,
/// а готовые lease доезжают фоновыми задачами. До готовности `url(for:)`
/// отдаёт путь из последнего известного расположения — путь может оказаться
/// устаревшим после перемещения файла, пропавшие источники ловит
/// `MediaAvailabilityMonitor`.
@MainActor
final class MediaAccessCoordinator {
    private struct Access {
        let reference: MediaReference
        let lease: MediaAccessLease
    }

    private var accessBySourceID: [UUID: Access] = [:]
    private var generation = Generation()

    /// Синхронный вызов: убирает ушедшие источники и ставит резолв новых
    /// в очередь; дисковая работа идёт вне главного потока. Повторный вызов
    /// с тем же источником не плодит задачу — уже решённые отсекаются
    /// сравнением reference.
    func synchronize(_ sources: [MediaReference]) {
        let gen = generation.advance()
        let currentIDs = Set(sources.map(\.id))
        accessBySourceID = accessBySourceID.filter { currentIDs.contains($0.key) }
        for source in sources where accessBySourceID[source.id]?.reference != source {
            Task.detached { [weak self] in
                let lease = source.makeAccessLease()
                await self?.apply(lease, resolving: source, generation: gen)
            }
        }
    }

    /// Готовый lease либо путь из последнего известного расположения —
    /// без проверок существования и без распаковки bookmark.
    func url(for source: MediaReference) -> URL? {
        if let access = accessBySourceID[source.id], access.reference == source {
            return access.lease.url
        }
        return URL(fileURLWithPath: source.lastKnownPath)
    }

    func stopAll() {
        _ = generation.advance()
        accessBySourceID.removeAll()
    }

    /// Применяет результат фоновой задачи; результат устаревшего поколения
    /// отбрасывается. `nil` от резолва — записи в словаре нет, `url(for:)`
    /// продолжает отдавать path-URL.
    private func apply(
        _ lease: sending MediaAccessLease?,
        resolving source: MediaReference,
        generation gen: Int
    ) {
        guard generation.isCurrent(gen), let lease else { return }
        accessBySourceID[source.id] = Access(reference: source, lease: lease)
    }
}
