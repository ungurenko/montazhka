import Foundation
import OSLog

/// Writer failure must finish every track even when its readiness callback stops.
final class TranscodeWatchdog: @unchecked Sendable {
    private struct State {
        var lastProgress = DispatchTime.now()
        var timedOut = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let timer: DispatchSourceTimer

    init(cancellation: MediaReaderPumpQueue, failed: @escaping @Sendable () -> Bool) {
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "montazhka.transcode.watchdog"))
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let stalled = self.state.withLock { state in
                if DispatchTime.now() > state.lastProgress + .seconds(30) { state.timedOut = true }
                return state.timedOut
            }
            if failed() || stalled { cancellation.cancel() }
        }
        timer.resume()
    }

    var timedOut: Bool { state.withLock { $0.timedOut } }
    func advanced() { state.withLock { $0.lastProgress = .now() } }
    func stop() {
        timer.setEventHandler(handler: nil)
        timer.cancel()
    }
    deinit { timer.cancel() }
}
