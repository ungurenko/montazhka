import Darwin
import Foundation

struct LocalProcessResult: Sendable {
    let exitCode: Int32
    let standardOutput: Data
}

/// Остановка запущенной программы: причина, группа процессов и переход от мягкой
/// просьбы (SIGTERM) к принудительной (SIGKILL). Сигналы идут только своей группе,
/// пока она существует; после сбора процесса мягкая просьба уже не шлётся.
private final class ProcessControl: @unchecked Sendable {
    enum Reason { case timeout, cancelled }

    private let lock = NSLock()
    private let grace: TimeInterval
    private var group: pid_t?
    private var reaped = false
    private(set) var reason: Reason?
    private var escalation: DispatchWorkItem?

    init(grace: TimeInterval) {
        self.grace = grace
    }

    /// Программа запущена своей группой. Остановку, запрошенную раньше запуска, выполняет сразу.
    func install(_ pid: pid_t) {
        let pending = lock.withLock {
            group = pid
            return reason != nil
        }
        if pending { signal() }
    }

    func stop(_ why: Reason) {
        let first = lock.withLock {
            guard reason == nil else { return false }
            reason = why
            return true
        }
        if first { signal() }
    }

    /// Главный процесс собран: мягкая просьба больше не нужна, принудительная остаётся за таймером.
    func markReaped() {
        lock.withLock { reaped = true }
    }

    /// Ждёт, пока группа опустеет или сработает принудительная остановка: после возврата
    /// у программы не остаётся живых детей.
    func waitForGroupToEnd() {
        guard let group = lock.withLock({ reason == nil ? nil : group }) else { return }
        let deadline = Date().addingTimeInterval(grace + 0.5)
        while Date() < deadline, killpg(group, 0) == 0 {
            usleep(20_000)
        }
        let stragglers = killpg(group, 0) == 0
        if stragglers { killpg(group, SIGKILL) }
        lock.withLock { escalation?.cancel() }
    }

    func cancelTimers() {
        lock.withLock { escalation?.cancel() }
    }

    private func signal() {
        let (target, soft) = lock.withLock { (group, !reaped) }
        guard let target else { return }
        if soft { killpg(target, SIGTERM) }
        let kill = DispatchWorkItem { killpg(target, SIGKILL) }
        lock.withLock { escalation = kill }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace, execute: kill)
    }
}

enum LocalProcessRunner {
    static let commandPath = [
        "/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin",
        "/usr/sbin", "/sbin",
    ].joined(separator: ":")

    static func executable(named name: String, extraPaths: [String] = []) -> URL? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        var candidates = extraPaths.map { home.appendingPathComponent($0).appendingPathComponent(name) }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        candidates += path.split(separator: ":").map {
            URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent(name)
        }
        candidates += [
            URL(fileURLWithPath: "/usr/local/bin/\(name)"),
            URL(fileURLWithPath: "/opt/homebrew/bin/\(name)"),
            home.appendingPathComponent(".local/bin/\(name)"),
        ]
        var seen = Set<String>()
        return candidates.first { candidate in
            seen.insert(candidate.path).inserted
                && fileManager.isExecutableFile(atPath: candidate.path)
        }
    }

    /// Запускает программу своей группой процессов и ждёт её. По таймауту и при отмене
    /// вся группа (с детьми) получает SIGTERM, а через `grace` — SIGKILL: управление
    /// возвращается в ограниченный срок, даже если программа не слушает сигналы или
    /// не читает вход. Запись во вход, закрытый программой, не роняет приложение (SIGPIPE).
    static func run(
        executable: URL,
        arguments: [String],
        input: Data? = nil,
        currentDirectory: URL? = nil,
        timeout: TimeInterval = 180,
        mergeStandardError: Bool = false,
        grace: TimeInterval = 1
    ) async throws -> LocalProcessResult {
        let control = ProcessControl(grace: grace)
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try runBlocking(
                    executable: executable, arguments: arguments, input: input, currentDirectory: currentDirectory,
                    timeout: timeout, mergeStandardError: mergeStandardError, control: control)
            }.value
        } onCancel: {
            control.stop(.cancelled)
        }
    }

    private static func runBlocking(
        executable: URL, arguments: [String], input: Data?, currentDirectory: URL?, timeout: TimeInterval,
        mergeStandardError: Bool, control: ProcessControl
    ) throws -> LocalProcessResult {
        let fileManager = FileManager.default
        let captureDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("montazhka-process-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: captureDirectory) }
        let outputURL = captureDirectory.appendingPathComponent("stdout")
        _ = fileManager.createFile(atPath: outputURL.path, contents: nil)

        var inputPipe: [Int32] = [-1, -1]
        if input != nil {
            guard pipe(&inputPipe) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            _ = fcntl(inputPipe[1], F_SETNOSIGPIPE, 1)
        }
        defer {
            for descriptor in inputPipe where descriptor >= 0 { Darwin.close(descriptor) }
        }

        let pid = try spawn(
            executable: executable, arguments: arguments, inputDescriptor: input == nil ? nil : inputPipe[0],
            outputPath: outputURL.path, mergeStandardError: mergeStandardError, currentDirectory: currentDirectory)
        control.install(pid)
        Darwin.close(inputPipe[0])
        inputPipe[0] = -1
        let timer = DispatchWorkItem { control.stop(.timeout) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timer)
        defer {
            timer.cancel()
            control.cancelTimers()
        }

        if let input {
            // Программа, которая не читает вход, держит запись до таймаута; вход, закрытый
            // программой (EPIPE), — её право: запись просто заканчивается.
            writeAll(input, to: inputPipe[1])
            Darwin.close(inputPipe[1])
            inputPipe[1] = -1
        }

        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1, errno == EINTR {}
        control.markReaped()
        control.waitForGroupToEnd()

        switch control.reason {
        case .timeout: throw AIProviderError.timeout(executable.lastPathComponent)
        case .cancelled: throw CancellationError()
        case nil: break
        }
        return LocalProcessResult(exitCode: exitCode(status), standardOutput: try Data(contentsOf: outputURL))
    }

    /// Код выхода как у `Process.terminationStatus`: номер сигнала, если программу убил сигнал.
    private static func exitCode(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : signal
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) {
        data.withUnsafeBytes { buffer in
            guard var cursor = buffer.baseAddress else { return }
            var left = buffer.count
            while left > 0 {
                let written = Darwin.write(descriptor, cursor, left)
                if written < 0 {
                    if errno == EINTR { continue }
                    return
                }
                cursor += written
                left -= written
            }
        }
    }

    /// Новая группа процессов с программой во главе; из открытых файлов наследуются
    /// только вход, выход и ошибки. Сигналы у программы — по умолчанию.
    private static func spawn(
        executable: URL, arguments: [String], inputDescriptor: Int32?, outputPath: String,
        mergeStandardError: Bool, currentDirectory: URL?
    ) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if let inputDescriptor {
            posix_spawn_file_actions_adddup2(&actions, inputDescriptor, STDIN_FILENO)
        } else {
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, outputPath, O_WRONLY | O_TRUNC, 0)
        if mergeStandardError {
            posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO)
        } else {
            posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        }
        if let currentDirectory {
            posix_spawn_file_actions_addchdir_np(&actions, currentDirectory.path)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var everySignal = sigset_t()
        sigfillset(&everySignal)
        posix_spawnattr_setsigdefault(&attributes, &everySignal)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)

        var environment = ProcessInfo.processInfo.environment
        let inheritedPath = environment["PATH"] ?? ""
        environment["PATH"] = commandPath + (inheritedPath.isEmpty ? "" : ":\(inheritedPath)")
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable.path, &actions, &attributes, argv, envp)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
        return pid
    }
}
