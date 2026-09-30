import Foundation
import Testing

@testable import MontazhkaKit

@Suite("Shorts window scheduling")
struct ShortsWindowSchedulingTests {
    @Test("a free slot starts the next window while the first window is still suspended")
    func refillsSlotsAndKeepsInputOrder() async throws {
        let probe = WindowSchedulingProbe()
        let progress = WindowSchedulingProgress()
        let configuration = AIRequestConfiguration.openRouter(model: .qwen, effort: nil, apiKey: "fixture")
        let task = start(count: 6, limit: configuration.maxConcurrentWindows, probe: probe, progress: progress)
        defer { task.cancel() }

        try await probe.waitForStarts([0, 1, 2])
        await probe.finish(1)
        try await probe.waitForStarts([3])
        #expect(!(await probe.snapshot.finished.contains(0)))
        await probe.finish(3)
        try await probe.waitForStarts([4])
        await probe.finish(4)
        try await probe.waitForStarts([5])
        await probe.finish(5)
        await probe.finish(2)
        await probe.finish(0)

        let result = try await task.value
        #expect(result.values == (0..<6).map { Optional($0) })
        #expect(result.failed == 0)
        #expect(result.lastError == nil)
        let snapshot = await probe.snapshot
        #expect(snapshot.peakActive == 3)
        #expect(snapshot.active == 0)
        let reported = await progress.values
        #expect(reported.first == 0)
        #expect(reported.last == 6)
        #expect(reported == reported.sorted())
    }

    @Test("both CLI providers keep only one active window", arguments: [AIProvider.codexCLI, .openCodeCLI])
    func serialProvidersKeepTheirLimit(_ provider: AIProvider) async throws {
        let executable = URL(fileURLWithPath: "/unused/fixture-agent")
        let configuration: AIRequestConfiguration =
            provider == .codexCLI
            ? .codexCLI(modelID: "fixture", effort: nil, executable: executable)
            : .openCodeCLI(modelID: "fixture", effort: nil, executable: executable)
        let probe = WindowSchedulingProbe()
        let task = start(count: 4, limit: configuration.maxConcurrentWindows, probe: probe)
        defer { task.cancel() }

        for index in 0..<4 {
            try await probe.waitForStarts([index])
            let snapshot = await probe.snapshot
            #expect(snapshot.started == Set(0...index))
            #expect(snapshot.peakActive == 1)
            await probe.finish(index)
        }
        let result = try await task.value
        #expect(result.values == (0..<4).map { Optional($0) })
        #expect(await probe.snapshot.active == 0)
    }

    @Test("partial failures preserve successes and choose the highest failed input index")
    func partialFailuresUseInputOrderForLastError() async throws {
        let probe = WindowSchedulingProbe()
        let task = start(count: 6, limit: 3, probe: probe)
        defer { task.cancel() }

        try await probe.waitForStarts([0, 1, 2])
        await probe.finish(2)
        try await probe.waitForStarts([3])
        await probe.finish(3, error: WindowSchedulingFailure.window(3))
        try await probe.waitForStarts([4])
        await probe.finish(4, error: WindowSchedulingFailure.window(4))
        try await probe.waitForStarts([5])
        await probe.finish(5)
        // A lower-index failure arrives later than the highest-index failure.
        await probe.finish(1, error: WindowSchedulingFailure.window(1))
        await probe.finish(0)

        let result = try await task.value
        #expect(result.values == [0, nil, 2, nil, nil, 5])
        #expect(result.failed == 3)
        #expect(result.lastError as? WindowSchedulingFailure == .window(4))
        #expect(await probe.snapshot.started == Set(0..<6))
        #expect(await probe.snapshot.peakActive <= 3)
    }

    @Test("a fully failed pass reports every failure and the highest-index error")
    func allFailuresUseInputOrderForLastError() async throws {
        let probe = WindowSchedulingProbe()
        let task = start(count: 3, limit: 3, probe: probe)
        defer { task.cancel() }

        try await probe.waitForStarts([0, 1, 2])
        for index in [2, 1, 0] {
            await probe.finish(index, error: WindowSchedulingFailure.window(index))
        }

        let result = try await task.value
        #expect(result.values == [nil, nil, nil])
        #expect(result.failed == 3)
        #expect(result.lastError as? WindowSchedulingFailure == .window(2))
    }

    @Test("parent cancellation cancels active work and never starts queued windows")
    func parentCancellationStopsQueuedWork() async throws {
        let probe = WindowSchedulingProbe()
        let task = start(count: 10, limit: 3, probe: probe)
        defer { task.cancel() }

        try await probe.waitForStarts([0, 1, 2])
        task.cancel()
        try await probe.waitForFinishes([0, 1, 2])
        try #require(await probe.snapshot.started == Set([0, 1, 2]))
        await #expect(throws: CancellationError.self) { try await task.value }

        let snapshot = await probe.snapshot
        #expect(snapshot.started == Set([0, 1, 2]))
        #expect(snapshot.active == 0)
    }

    @Test("a cancelled window cancels siblings and never starts queued windows")
    func workerCancellationStopsQueuedWork() async throws {
        let probe = WindowSchedulingProbe()
        let task = start(count: 10, limit: 3, probe: probe)
        defer { task.cancel() }

        try await probe.waitForStarts([0, 1, 2])
        await probe.finish(2, error: CancellationError())
        try await probe.waitForFinishes([0, 1, 2])
        try #require(await probe.snapshot.started == Set([0, 1, 2]))
        await #expect(throws: CancellationError.self) { try await task.value }

        let snapshot = await probe.snapshot
        #expect(snapshot.started == Set([0, 1, 2]))
        #expect(snapshot.active == 0)
    }

    @Test("an already cancelled caller does not start any window")
    func alreadyCancelledCallerStartsNoWork() async throws {
        let probe = WindowSchedulingProbe()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ShortsCutService.runWindows(
                count: 6, limit: 3, status: { _ in }, work: { try await probe.work($0) })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await probe.snapshot.started.isEmpty)
    }

    private func start(
        count: Int, limit: Int, probe: WindowSchedulingProbe,
        progress: WindowSchedulingProgress = WindowSchedulingProgress()
    ) -> Task<ShortsCutService.WindowRun<Int>, any Error> {
        Task {
            try await ShortsCutService.runWindows(
                count: count, limit: limit,
                status: { await progress.append($0) }, work: { try await probe.work($0) })
        }
    }
}

private enum WindowSchedulingFailure: Error, Equatable {
    case window(Int)
    case startsTimedOut(Set<Int>)
    case finishesTimedOut(Set<Int>)
}

/// Workers suspend until the test explicitly completes or cancels them.
/// The short deadline only prevents a broken scheduler from hanging the suite.
private actor WindowSchedulingProbe {
    struct Snapshot: Sendable {
        let started: Set<Int>
        let finished: Set<Int>
        let active: Int
        let peakActive: Int
    }

    private var continuations: [Int: CheckedContinuation<Int, any Error>] = [:]
    private var started = Set<Int>()
    private var finished = Set<Int>()
    private var peakActive = 0

    var snapshot: Snapshot {
        Snapshot(started: started, finished: finished, active: continuations.count, peakActive: peakActive)
    }

    func work(_ index: Int) async throws -> Int {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                continuations[index] = continuation
                started.insert(index)
                peakActive = max(peakActive, continuations.count)
            }
        } onCancel: {
            Task { await self.finish(index, error: CancellationError()) }
        }
    }

    func finish(_ index: Int, error: (any Error)? = nil) {
        guard let continuation = continuations.removeValue(forKey: index) else { return }
        finished.insert(index)
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: index)
        }
    }

    func waitForStarts(_ expected: Set<Int>) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !expected.isSubset(of: started) {
            guard ContinuousClock.now < deadline else {
                throw WindowSchedulingFailure.startsTimedOut(expected.subtracting(started))
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func waitForFinishes(_ expected: Set<Int>) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !expected.isSubset(of: finished) {
            guard ContinuousClock.now < deadline else {
                throw WindowSchedulingFailure.finishesTimedOut(expected.subtracting(finished))
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor WindowSchedulingProgress {
    private(set) var values: [Int] = []
    func append(_ value: Int) { values.append(value) }
}
