import CryptoKit
import Darwin
import Foundation

@testable import MontazhkaKit

/// An acceptance experiment, independent of the product's activation gate.
/// Fixtures are generated once; every measured export runs in a fresh process.
@main
struct ExportResolutionBenchmark {
    private struct Options {
        var phase = "prepare"
        var caseID = "freeze-sdr-medium"
        var engine = "native"
        var pair = 1
        var root = URL(fileURLWithPath: ".build/performance-review/export-resolution", isDirectory: true)

        init(_ arguments: [String]) throws {
            var index = 0
            while index < arguments.count {
                guard index + 1 < arguments.count else {
                    throw ExportResolutionFixture.Failure(reason: "Missing value for \(arguments[index]).")
                }
                let value = arguments[index + 1]
                switch arguments[index] {
                case "--phase": phase = value
                case "--case": caseID = value
                case "--engine": engine = value
                case "--pair": pair = Int(value) ?? 0
                case "--root": root = URL(fileURLWithPath: value, isDirectory: true)
                default: throw ExportResolutionFixture.Failure(reason: "Unknown argument \(arguments[index]).")
                }
                index += 2
            }
            guard ["prepare", "matrix", "sample", "summary"].contains(phase),
                ["native", "target"].contains(engine), (1...5).contains(pair),
                ExportResolutionFixture.cases.contains(where: { $0.id == caseID })
            else { throw ExportResolutionFixture.Failure(reason: "Invalid benchmark arguments.") }
        }
    }

    private struct MatrixRecord: Codable {
        let benchmarkBuildID: String
        let caseID: String
        let compatible: Bool
        let issues: [String]
        let baselineRepeat: ExportResolutionFixture.PixelDifference?
        let candidateDifference: ExportResolutionFixture.PixelDifference?
        let baseline: ExportResolutionFixture.FileInfo?
        let candidate: ExportResolutionFixture.FileInfo?

        init(_ report: ExportResolutionFixture.Report, buildID: String) {
            benchmarkBuildID = buildID
            caseID = report.caseID
            compatible = report.compatible
            issues = report.issues
            baselineRepeat = report.baselineRepeat
            candidateDifference = report.candidateDifference
            baseline = report.baseline
            candidate = report.candidate
        }

        init(caseID: String, error: any Error, buildID: String) {
            benchmarkBuildID = buildID
            self.caseID = caseID
            compatible = false
            issues = ["\(error.localizedDescription) [\(String(reflecting: error))]"]
            baselineRepeat = nil
            candidateDifference = nil
            baseline = nil
            candidate = nil
        }
    }

    private struct Sample: Codable {
        let benchmarkBuildID: String
        let caseID: String
        let engine: String
        let pair: Int
        let elapsedMS: Double
        let cpuMS: Double
        let peakRSSBytes: Int
        let dimensions: [Int]
        let frameCount: Int
        let duration: Double
        let audioDigest: String
        let outputPath: String
    }

    private struct PerformanceReport: Codable {
        let caseID: String
        let pairedRuns: Int
        let nativeMedianMS: Double
        let targetMedianMS: Double
        let improvementPercent: Double
        let medianPairedSavingMS: Double
        let noiseThresholdMS: Double
        let smallestPairedSavingMS: Double
        let speedAboveNoise: Bool
        let nativeMedianCPU_MS: Double
        let targetMedianCPU_MS: Double
        let nativeMedianPeakRSSBytes: Int
        let targetMedianPeakRSSBytes: Int
    }

    private struct GateReport: Codable {
        let benchmarkBuildID: String
        let matrixCases: Int
        let compatible: Bool
        let speedAboveNoise: Bool
        let eligibleToEnable: Bool
        let productGateChanged: Bool
        let incompatibleCases: [String]
        let missingCases: [String]
        let pixelToleranceRule: String
        let speedRule: String
        let performance: [PerformanceReport]
    }

    private static let performanceCases = ["freeze-sdr-medium", "freeze-sdr-compact"]

    static func main() async throws {
        let options = try Options(Array(CommandLine.arguments.dropFirst()))
        let buildID = try benchmarkBuildID()
        let item = ExportResolutionFixture.cases.first { $0.id == options.caseID }!
        switch options.phase {
        case "prepare":
            try await ExportResolutionFixture.prepare(at: options.root)
            try emit(["phase": "prepare", "root": options.root.path, "sourceSize": "3840x2160"])
        case "matrix":
            do {
                try emit(MatrixRecord(try await ExportResolutionFixture.verify(item, root: options.root), buildID: buildID))
            } catch {
                // A failed case is evidence against activation, and does not hide later cases.
                try emit(MatrixRecord(caseID: item.id, error: error, buildID: buildID))
            }
        case "sample":
            try emit(try await measure(item, options: options, buildID: buildID))
        case "summary":
            try emit(try summary(root: options.root, buildID: buildID))
        default:
            preconditionFailure("Options validated the phase.")
        }
    }

    private static func measure(
        _ item: ExportResolutionFixture.Case, options: Options, buildID: String
    ) async throws -> Sample {
        let directory = options.root.appendingPathComponent("samples", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "\(item.id)-\(options.engine)-\(options.pair)"
        let warmup = directory.appendingPathComponent("\(name)-warmup.mp4")
        let output = directory.appendingPathComponent("\(name).mp4")
        let quality: ExportQuality? = options.engine == "target" ? item.quality : nil

        // Warm the selected route in this process. Source generation is outside it.
        try await perform(item, root: options.root, quality: quality, output: warmup)
        try await Task.sleep(for: .milliseconds(50))
        let startCPU = usage().cpu
        let clock = ContinuousClock()
        let start = clock.now
        try await perform(item, root: options.root, quality: quality, output: output)
        let elapsed = seconds(clock.now - start) * 1_000
        let finished = usage()
        let cpu = (finished.cpu - startCPU) * 1_000

        // Integrity inspection is outside the timed export.
        let info = try await ExportResolutionFixture.inspect(output)
        guard info.width == Int(item.outputSize.width), info.height == Int(item.outputSize.height),
            !info.frameTimes.isEmpty, abs(info.duration - item.duration) <= 1.0 / 30 + 0.002
        else { throw ExportResolutionFixture.Failure(reason: "A measured export has unexpected geometry or duration.") }
        return Sample(
            benchmarkBuildID: buildID, caseID: item.id, engine: options.engine, pair: options.pair, elapsedMS: elapsed, cpuMS: cpu,
            peakRSSBytes: finished.peak, dimensions: [info.width, info.height],
            frameCount: info.frameTimes.count, duration: info.duration, audioDigest: info.audioDigest,
            outputPath: output.path)
    }

    private static func perform(
        _ item: ExportResolutionFixture.Case, root: URL, quality: ExportQuality?, output: URL
    ) async throws {
        let scene = ExportResolutionFixture.scene(item, root: root)
        let rendered = try await ExportResolutionFixture.render(scene, quality: quality)
        try await ExportResolutionFixture.export(rendered, item: item, to: output)
    }

    private static func summary(root: URL, buildID: String) throws -> GateReport {
        let matrix: [MatrixRecord] = try lines(root.appendingPathComponent("matrix.jsonl"))
        let samples: [Sample] = try lines(root.appendingPathComponent("pairs.jsonl"))
        let expectedIDs = Set(ExportResolutionFixture.cases.map(\.id))
        let actualIDs = Set(matrix.map(\.caseID))
        let sameBuild = matrix.allSatisfy { $0.benchmarkBuildID == buildID }
            && samples.allSatisfy { $0.benchmarkBuildID == buildID }
        guard sameBuild else {
            throw ExportResolutionFixture.Failure(reason: "Matrix and sample evidence belongs to a different benchmark build.")
        }
        let compatible = matrix.count == expectedIDs.count && actualIDs == expectedIDs && matrix.allSatisfy(\.compatible)
        let performance = try performanceCases.map { caseID -> PerformanceReport in
            let before = samples.filter { $0.caseID == caseID && $0.engine == "native" }.sorted { $0.pair < $1.pair }
            let after = samples.filter { $0.caseID == caseID && $0.engine == "target" }.sorted { $0.pair < $1.pair }
            guard before.map(\.pair) == Array(1...5), after.map(\.pair) == Array(1...5) else {
                throw ExportResolutionFixture.Failure(reason: "\(caseID) does not have five complete pairs.")
            }
            guard zip(before, after).allSatisfy({ a, b in
                a.dimensions == b.dimensions && a.frameCount == b.frameCount
                    && abs(a.duration - b.duration) <= 1.0 / 600 + 0.0001 && a.audioDigest == b.audioDigest
            }) else { throw ExportResolutionFixture.Failure(reason: "The measured paths returned different file structures.") }
            let native = median(before.map(\.elapsedMS))
            let target = median(after.map(\.elapsedMS))
            let savings = zip(before, after).map { $0.elapsedMS - $1.elapsedMS }
            let noise = max(
                native * 0.01, 3 * max(deviation(before.map(\.elapsedMS)), deviation(after.map(\.elapsedMS))))
            let medianSaving = median(savings)
            let smallestSaving = savings.min()!
            return PerformanceReport(
                caseID: caseID, pairedRuns: 5, nativeMedianMS: native, targetMedianMS: target,
                improvementPercent: (native - target) / native * 100, medianPairedSavingMS: medianSaving,
                noiseThresholdMS: noise, smallestPairedSavingMS: smallestSaving,
                speedAboveNoise: medianSaving > noise && smallestSaving > 0,
                nativeMedianCPU_MS: median(before.map(\.cpuMS)), targetMedianCPU_MS: median(after.map(\.cpuMS)),
                nativeMedianPeakRSSBytes: Int(median(before.map { Double($0.peakRSSBytes) })),
                targetMedianPeakRSSBytes: Int(median(after.map { Double($0.peakRSSBytes) })))
        }
        let speed = performance.allSatisfy(\.speedAboveNoise)
        return GateReport(
            benchmarkBuildID: buildID, matrixCases: matrix.count, compatible: compatible, speedAboveNoise: speed,
            eligibleToEnable: compatible && speed, productGateChanged: false,
            incompatibleCases: matrix.filter { !$0.compatible }.map(\.caseID),
            missingCases: expectedIDs.subtracting(actualIDs).sorted(),
            pixelToleranceRule: "Candidate MAE, RMSE and max RGB error must not exceed the same-case native baseline repeat.",
            speedRule: "All five pairs must improve; median paired saving must exceed 3x max MAD and 1% of native median.",
            performance: performance)
    }

    private static func usage() -> (cpu: Double, peak: Int) {
        var value = rusage()
        getrusage(RUSAGE_SELF, &value)
        let cpu = Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec)
            + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1e6
        return (cpu, Int(value.ru_maxrss))
    }

    private static func benchmarkBuildID() throws -> String {
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: CommandLine.arguments[0]))
        defer { try? file.close() }
        var hash = SHA256()
        while let chunk = try file.read(upToCount: 64 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func seconds(_ value: Duration) -> Double {
        Double(value.components.seconds) + Double(value.components.attoseconds) / 1e18
    }

    private static func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
    private static func deviation(_ values: [Double]) -> Double {
        let middle = median(values)
        return median(values.map { abs($0 - middle) })
    }

    private static func lines<T: Decodable>(_ url: URL) throws -> [T] {
        try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline).map {
            try JSONDecoder().decode(T.self, from: Data($0.utf8))
        }
    }

    private static func emit<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(value)
        data.append(0x0a)
        try FileHandle.standardOutput.write(contentsOf: data)
    }
}
