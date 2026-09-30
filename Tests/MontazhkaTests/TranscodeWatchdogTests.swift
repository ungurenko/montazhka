import Foundation
import Testing
import os

@testable import MontazhkaKit

@Suite
struct TranscodeWatchdogTests {
    @Test("writer failure finishes both tracks without another readiness callback")
    func writerFailureStopsEveryTrack() async throws {
        let stops = OSAllocatedUnfairLock(initialState: 0)
        let tracks = OSAllocatedUnfairLock(initialState: 0)
        let cancellation = MediaReaderPumpQueue(label: "test.writer.failure") {
            stops.withLock { $0 += 1 }
        }
        await withCheckedContinuation { (ready: CheckedContinuation<Void, Never>) in
            cancellation.queue.async {
                for _ in 0..<2 { cancellation.onCancel { tracks.withLock { $0 += 1 } } }
                ready.resume()
            }
        }
        let watchdog = TranscodeWatchdog(cancellation: cancellation, failed: { true })
        defer { watchdog.stop() }
        let deadline = ContinuousClock.now + .seconds(3)
        while tracks.withLock({ $0 }) < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(tracks.withLock { $0 } == 2)
        #expect(stops.withLock { $0 } == 1)
    }
}
