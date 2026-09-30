import Foundation
import Testing
import os

@testable import MontazhkaKit

@Suite("Media reader cancellation ordering")
struct MediaReaderPumpQueueTests {
    @Test("cancellation waits for the current read and finishes both tracks once")
    func cancelDuringRead() async {
        let events = OSAllocatedUnfairLock(initialState: [String]())
        let pump = MediaReaderPumpQueue(label: "test.reader") {
            events.withLock { $0.append("cancel") }
        }
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        pump.queue.async {
            pump.onCancel { events.withLock { $0.append("video") } }
            pump.onCancel { events.withLock { $0.append("audio") } }
            events.withLock { $0.append("reading") }
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
            events.withLock { $0.append("read ended") }
        }
        let started = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: entered.wait(timeout: .now() + 5) == .success)
            }
        }
        #expect(started)
        pump.cancel()
        pump.cancel()
        #expect(pump.isCancelled)
        #expect(events.withLock { $0 } == ["reading"])
        release.signal()
        await drain(pump)
        #expect(events.withLock { $0 } == ["reading", "read ended", "cancel", "video", "audio"])
    }

    @Test("cancel before registration finishes late tracks without another reader cancel")
    func cancelBeforeStart() async {
        let events = OSAllocatedUnfairLock(initialState: [String]())
        let pump = MediaReaderPumpQueue(label: "test.reader.early") {
            events.withLock { $0.append("cancel") }
        }
        pump.cancel()
        pump.cancel()
        pump.queue.async {
            pump.onCancel { events.withLock { $0.append("video") } }
            pump.onCancel { events.withLock { $0.append("audio") } }
            pump.stopOnQueue()
        }
        await drain(pump)
        #expect(events.withLock { $0 } == ["cancel", "video", "audio"])
    }

    private func drain(_ pump: MediaReaderPumpQueue) async {
        await withCheckedContinuation { continuation in
            pump.queue.async { continuation.resume() }
        }
    }
}
