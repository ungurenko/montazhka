import AppKit

private final class LocalEventBox: @unchecked Sendable {
    let event: NSEvent

    init(_ event: NSEvent) {
        self.event = event
    }
}

/// Прячет несовместимость NSEvent со строгой конкурентностью Swift 6.
/// AppKit вызывает локальные мониторы синхронно на главном потоке.
@MainActor
final class LocalEventMonitor {
    private var token: Any?

    func install(
        matching mask: NSEvent.EventTypeMask,
        handler: @escaping @MainActor (NSEvent) -> NSEvent?
    ) {
        remove()
        token = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            let box = LocalEventBox(event)
            let result = MainActor.assumeIsolated {
                handler(box.event).map(LocalEventBox.init)
            }
            return result?.event
        }
    }

    func remove() {
        if let token {
            NSEvent.removeMonitor(token)
            self.token = nil
        }
    }

    deinit {
        MainActor.assumeIsolated {
            remove()
        }
    }
}
