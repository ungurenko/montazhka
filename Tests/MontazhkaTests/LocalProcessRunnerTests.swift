import Darwin
import Foundation
import Testing

@testable import MontazhkaKit

/// Внешняя программа (CLI модели) не держит Монтажку дольше таймаута: даже если она
/// не слушает просьбу завершиться, не читает вход и запустила своих детей.
@Suite("Local process runner")
struct LocalProcessRunnerTests {
    private let shell = URL(fileURLWithPath: "/bin/sh")

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno != ESRCH
    }

    @Test("a program that ignores SIGTERM is stopped within the timeout, children included")
    func ignoredTermStillTimesOut() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appendingPathComponent("child.pid")
        let started = ContinuousClock.now

        await #expect(throws: AIProviderError.self) {
            _ = try await LocalProcessRunner.run(
                executable: shell,
                arguments: ["-c", "trap '' TERM; sleep 30 & echo $! > '\(pidFile.path)'; wait"],
                timeout: 1)
        }

        #expect(ContinuousClock.now - started < .seconds(8), "вернулся за \(ContinuousClock.now - started)")
        let child = pid_t(
            try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
        let pid = try #require(child)
        for _ in 0..<50 where isAlive(pid) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!isAlive(pid), "дочерний процесс программы тоже остановлен")
    }

    @Test("a program that never reads a large input times out instead of blocking the write")
    func unreadInputTimesOut() async throws {
        let started = ContinuousClock.now

        await #expect(throws: AIProviderError.self) {
            _ = try await LocalProcessRunner.run(
                executable: shell, arguments: ["-c", "trap '' TERM; sleep 30"],
                input: Data(count: 4 * 1024 * 1024), timeout: 1)
        }

        #expect(ContinuousClock.now - started < .seconds(8))
    }

    @Test("cancelling the task stops the program quickly")
    func cancellationStopsProgram() async throws {
        let shell = self.shell
        let task = Task {
            try await LocalProcessRunner.run(
                executable: shell, arguments: ["-c", "trap '' TERM; sleep 30"], timeout: 60)
        }
        try await Task.sleep(for: .milliseconds(200))
        let started = ContinuousClock.now
        task.cancel()

        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(ContinuousClock.now - started < .seconds(8))
    }

    @Test("a program that exits on its own returns its code, output and input echo")
    func earlyExitReturnsResult() async throws {
        let result = try await LocalProcessRunner.run(
            executable: shell, arguments: ["-c", "cat; echo конец; exit 3"], input: Data("вход\n".utf8), timeout: 10)

        #expect(result.exitCode == 3)
        #expect(String(decoding: result.standardOutput, as: UTF8.self) == "вход\nконец\n")
    }
}
