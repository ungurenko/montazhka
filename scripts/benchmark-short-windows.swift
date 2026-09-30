import CryptoKit
import Darwin
import Foundation

@testable import MontazhkaKit

/// Compares the production scheduler with its previous batching implementation.
/// Work is local arithmetic plus fixed simulated latency; no models, CLI agents or APIs run.
@main
struct ShortsWindowBenchmark {
    private enum Scheduler: String {
        case batchingReference
        case current
    }

    private struct Sample: Codable {
        let profile: String
        let pair: Int
        let scheduler: String
        let elapsedMS: Double
        let cpuMS: Double
        let peakRSSBytes: Int
        let peakConcurrent: Int
        let startedCount: Int
        let resultDigest: String
    }

    private struct Summary: Codable {
        let profile: String
        let pairedRuns: Int
        let batchingMedianMS: Double
        let currentMedianMS: Double
        let improvementPercent: Double
        let identicalResults: Bool
        let simulatedLatenciesMS: [Int]
        let localIterationsPerWindow: Int
    }

    private struct Failure: Error {
        let reason: String
    }

    private static let delays = [120, 5, 5, 120, 5, 5, 120, 5, 5, 120, 5, 5]
    private static let localIterations = 100_000

    static func main() async throws {
        for (profile, limit) in [("openrouter-limit-3", 3), ("cli-limit-1", 1)] {
            for scheduler in [Scheduler.batchingReference, .current] {
                _ = try await measure(scheduler, profile: profile, pair: -1, limit: limit)
            }
            var samples: [Sample] = []
            for pair in 0..<5 {
                let order: [Scheduler] = pair.isMultiple(of: 2)
                    ? [.batchingReference, .current] : [.current, .batchingReference]
                for scheduler in order {
                    let sample = try await measure(scheduler, profile: profile, pair: pair + 1, limit: limit)
                    samples.append(sample)
                    try emit(sample)
                }
            }
            guard Set(samples.map(\.resultDigest)).count == 1 else {
                throw Failure(reason: "Paired schedulers returned different ordered results.")
            }
            let before = median(samples.filter { $0.scheduler == Scheduler.batchingReference.rawValue }.map(\.elapsedMS))
            let after = median(samples.filter { $0.scheduler == Scheduler.current.rawValue }.map(\.elapsedMS))
            try emit(
                Summary(
                    profile: profile, pairedRuns: 5, batchingMedianMS: before, currentMedianMS: after,
                    improvementPercent: (before - after) / before * 100, identicalResults: true,
                    simulatedLatenciesMS: delays, localIterationsPerWindow: localIterations))
        }
    }

    private static func measure(
        _ scheduler: Scheduler, profile: String, pair: Int, limit: Int
    ) async throws -> Sample {
        let probe = BenchmarkWindowProbe()
        let startCPU = cpuSeconds()
        let clock = ContinuousClock()
        let start = clock.now
        let work: @Sendable (Int) async throws -> UInt64 = { index in
            await probe.begin(index)
            do {
                let checksum = localWork(index)
                try await Task.sleep(for: .milliseconds(delays[index]))
                await probe.end(index)
                return checksum
            } catch {
                await probe.end(index)
                throw error
            }
        }
        let result: ShortsCutService.WindowRun<UInt64>
        switch scheduler {
        case .batchingReference:
            result = try await batchingReference(
                count: delays.count, limit: limit, status: { await probe.progress($0) }, work: work)
        case .current:
            result = try await ShortsCutService.runWindows(
                count: delays.count, limit: limit, status: { await probe.progress($0) }, work: work)
        }
        let elapsedMS = seconds(clock.now - start) * 1_000
        let cpuMS = (cpuSeconds() - startCPU) * 1_000
        let expected = delays.indices.map { Optional(localWork($0)) }
        let snapshot = await probe.snapshot
        guard result.values == expected, result.failed == 0, result.lastError == nil,
            snapshot.active == 0, snapshot.peak <= limit, snapshot.started == Set(delays.indices),
            snapshot.progress.first == 0, snapshot.progress.last == delays.count,
            snapshot.progress == snapshot.progress.sorted()
        else { throw Failure(reason: "Ordered results, concurrency, completion or progress changed.") }

        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let data = try JSONEncoder().encode(result.values)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return Sample(
            profile: profile, pair: pair, scheduler: scheduler.rawValue, elapsedMS: elapsedMS, cpuMS: cpuMS,
            peakRSSBytes: Int(usage.ru_maxrss), peakConcurrent: snapshot.peak, startedCount: snapshot.started.count,
            resultDigest: digest)
    }

    /// Reference copied from runWindows before the rolling queue change.
    private static func batchingReference<Value: Sendable>(
        count: Int, limit: Int,
        status: @escaping @Sendable (Int) async -> Void,
        work: @escaping @Sendable (Int) async throws -> Value
    ) async throws -> ShortsCutService.WindowRun<Value> {
        var values = [Value?](repeating: nil, count: count)
        var failed = 0
        var lastError: (any Error)?
        let batchSize = max(1, limit)
        await status(0)
        for batchStart in stride(from: 0, to: count, by: batchSize) {
            try Task.checkCancellation()
            let batchEnd = min(batchStart + batchSize, count)
            let results = await withTaskGroup(of: (Int, Result<Value, any Error>).self) { group in
                for index in batchStart..<batchEnd {
                    group.addTask {
                        do { return (index, .success(try await work(index))) }
                        catch { return (index, .failure(error)) }
                    }
                }
                var collected: [(Int, Result<Value, any Error>)] = []
                for await result in group { collected.append(result) }
                return collected
            }
            for (index, result) in results.sorted(by: { $0.0 < $1.0 }) {
                switch result {
                case .success(let value): values[index] = value
                case .failure(let error):
                    if error is CancellationError { throw CancellationError() }
                    failed += 1
                    lastError = error
                }
            }
            await status(batchEnd)
        }
        return ShortsCutService.WindowRun(values: values, failed: failed, lastError: lastError)
    }

    @inline(never)
    private nonisolated static func localWork(_ index: Int) -> UInt64 {
        var value = UInt64(index + 1)
        for offset in 0..<localIterations {
            value = (value &* 6_364_136_223_846_793_005) &+ UInt64(offset)
            value ^= value >> 23
        }
        return value
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }

    private static func seconds(_ value: Duration) -> Double {
        Double(value.components.seconds) + Double(value.components.attoseconds) / 1e18
    }

    private static func median(_ values: [Double]) -> Double {
        values.sorted()[values.count / 2]
    }

    private static func emit<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }
}

private actor BenchmarkWindowProbe {
    private var active = Set<Int>()
    private var started = Set<Int>()
    private var peak = 0
    private var reported: [Int] = []

    var snapshot: (active: Int, started: Set<Int>, peak: Int, progress: [Int]) {
        (active.count, started, peak, reported)
    }

    func begin(_ index: Int) {
        started.insert(index)
        active.insert(index)
        peak = max(peak, active.count)
    }

    func end(_ index: Int) { active.remove(index) }
    func progress(_ value: Int) { reported.append(value) }
}
