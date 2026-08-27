import Foundation

struct LocalProcessResult: Sendable {
    let exitCode: Int32
    let standardOutput: Data
}

private final class RunningProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var timedOut = false
    private var terminationRequested = false

    func install(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        self.process = process
        return !terminationRequested
    }

    func finish() {
        lock.lock()
        process = nil
        lock.unlock()
    }

    func terminate(timedOut: Bool = false) {
        lock.lock()
        if timedOut { self.timedOut = true }
        terminationRequested = true
        let running = process
        lock.unlock()
        if running?.isRunning == true { running?.terminate() }
    }

    func terminateIfRequested() {
        lock.lock()
        let shouldTerminate = terminationRequested
        let running = process
        lock.unlock()
        if shouldTerminate, running?.isRunning == true { running?.terminate() }
    }

    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    var didRequestTermination: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminationRequested
    }
}

enum LocalProcessRunner {
    static let commandPath = [
        "/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin",
        "/usr/sbin", "/sbin",
    ].joined(separator: ":")

    static func run(
        executable: URL,
        arguments: [String],
        input: Data? = nil,
        currentDirectory: URL? = nil,
        timeout: TimeInterval = 180
    ) async throws -> LocalProcessResult {
        let box = RunningProcessBox()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                let fileManager = FileManager.default
                let captureDirectory = fileManager.temporaryDirectory
                    .appendingPathComponent("montazhka-process-\(UUID().uuidString)", isDirectory: true)
                try fileManager.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
                defer { try? fileManager.removeItem(at: captureDirectory) }

                let outputURL = captureDirectory.appendingPathComponent("stdout")
                _ = fileManager.createFile(atPath: outputURL.path, contents: nil)
                let outputHandle = try FileHandle(forWritingTo: outputURL)
                defer { try? outputHandle.close() }

                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.currentDirectoryURL = currentDirectory
                var environment = ProcessInfo.processInfo.environment
                let inheritedPath = environment["PATH"] ?? ""
                environment["PATH"] = commandPath + (inheritedPath.isEmpty ? "" : ":\(inheritedPath)")
                process.environment = environment
                process.standardOutput = outputHandle
                process.standardError = FileHandle.nullDevice

                let inputPipe: Pipe?
                if input != nil {
                    let pipe = Pipe()
                    process.standardInput = pipe
                    inputPipe = pipe
                } else {
                    inputPipe = nil
                }

                guard box.install(process) else { throw CancellationError() }
                do {
                    try process.run()
                } catch {
                    box.finish()
                    if box.didRequestTermination { throw CancellationError() }
                    throw error
                }

                box.terminateIfRequested()
                let timeoutWorkItem = DispatchWorkItem {
                    box.terminate(timedOut: true)
                }
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + timeout,
                    execute: timeoutWorkItem)

                if let input, let inputPipe {
                    do {
                        try inputPipe.fileHandleForWriting.write(contentsOf: input)
                    } catch {
                        if box.didRequestTermination {
                            if box.didTimeOut {
                                throw AIProviderError.timeout(executable.lastPathComponent)
                            }
                            throw CancellationError()
                        }
                        throw error
                    }
                    try? inputPipe.fileHandleForWriting.close()
                }
                process.waitUntilExit()
                timeoutWorkItem.cancel()
                box.finish()

                if box.didTimeOut { throw AIProviderError.timeout(executable.lastPathComponent) }
                if box.didRequestTermination { throw CancellationError() }

                try outputHandle.synchronize()
                return LocalProcessResult(
                    exitCode: process.terminationStatus,
                    standardOutput: try Data(contentsOf: outputURL))
            }.value
        } onCancel: {
            box.terminate()
        }
    }
}
