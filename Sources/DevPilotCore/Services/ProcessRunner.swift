import Darwin
import Foundation
import Synchronization

public struct ProcessRequest: Sendable {
    public var executable: URL
    public var arguments: [String]
    public var workingDirectory: URL
    /// The complete environment. Nothing is inherited from DevPilot's own process.
    public var environment: [String: String]
    public var stdin: Data?
    public var timeout: Duration
    /// Called with the child's PID (which is also its process group ID) once it has started.
    public var onLaunch: (@Sendable (pid_t) -> Void)?
    /// Agents, builds and tests run at utility QoS: macOS favours the efficiency cores for them
    /// and keeps the performance cores for the apps in use. nil leaves the default.
    public var qualityOfService: qos_class_t?
    /// Stops the child when it writes nothing (stdout or stderr) for this long, so a stuck process
    /// ends early while a busy one may use all of `timeout`.
    public var idleTimeout: Duration?

    public init(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String],
        stdin: Data? = nil,
        timeout: Duration,
        onLaunch: (@Sendable (pid_t) -> Void)? = nil,
        qualityOfService: qos_class_t? = QOS_CLASS_UTILITY,
        idleTimeout: Duration? = nil
    ) {
        self.idleTimeout = idleTimeout
        self.qualityOfService = qualityOfService
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.stdin = stdin
        self.timeout = timeout
        self.onLaunch = onLaunch
    }
}

public struct ProcessResult: Sendable {
    public enum Termination: Sendable, Equatable {
        case exited(Int32)
        case signaled(Int32)
    }

    public let termination: Termination
    public let stdout: Data
    public let stderr: Data
    public let timedOut: Bool
    /// Stopped by `idleTimeout` (also sets `timedOut`).
    public let stalled: Bool

    public var succeeded: Bool { termination == .exited(0) && !timedOut }
    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

public enum ProcessRunnerError: Error, Equatable, LocalizedError {
    case notExecutable(String)
    case missingWorkingDirectory(String)
    case launchFailed(String, errno: Int32)

    public var errorDescription: String? {
        switch self {
        case .notExecutable(let path): "\(path) is not an executable file."
        case .missingWorkingDirectory(let path): "Working directory '\(path)' does not exist."
        case .launchFailed(let path, let code): "Could not launch \(path): \(String(cString: strerror(code)))"
        }
    }
}

/// Runs child processes with `posix_spawn`: explicit executable and argument array (no shell),
/// a complete replacement environment, no inherited file descriptors, and a new process group so
/// timeouts, cancellation and app shutdown terminate the child and everything it started.
public enum ProcessRunner {
    public static let maxCapturedBytes = 32 * 1024 * 1024
    static let terminationGrace: Duration = .seconds(5)

    private static let liveGroups = Mutex<Set<pid_t>>([])

    /// Terminates every running child process group. Call when the app quits.
    public static func terminateAll() {
        for group in liveGroups.withLock({ $0 }) {
            killpg(group, SIGTERM)
        }
    }

    public static func run(
        _ request: ProcessRequest,
        onStdoutLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        try Task.checkCancellation()
        let path = request.executable.path
        guard FileManager.default.isExecutableFile(atPath: path) else { throw ProcessRunnerError.notExecutable(path) }
        // Never fall back to DevPilot's own current directory.
        var isDirectory: ObjCBool = false
        let directory = request.workingDirectory.path
        guard !directory.isEmpty, FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProcessRunnerError.missingWorkingDirectory(directory)
        }
        // A child that closes stdin early must not kill DevPilot with SIGPIPE.
        signal(SIGPIPE, SIG_IGN)

        let stdinPipe = try makePipe(path)
        let stdoutPipe = try makePipe(path)
        let stderrPipe = try makePipe(path)
        let pid: pid_t
        do {
            pid = try spawn(request, stdin: stdinPipe.read, stdout: stdoutPipe.write, stderr: stderrPipe.write)
        } catch {
            [stdinPipe.read, stdinPipe.write, stdoutPipe.read, stdoutPipe.write, stderrPipe.read, stderrPipe.write].forEach { close($0) }
            throw error
        }
        close(stdinPipe.read)
        close(stdoutPipe.write)
        close(stderrPipe.write)
        liveGroups.withLock { _ = $0.insert(pid) }
        request.onLaunch?(pid)

        let input = request.stdin ?? Data()
        let stdinFD = stdinPipe.write
        DispatchQueue.global().async {
            writeAll(stdinFD, input)
            close(stdinFD)
        }

        let lastOutput = Mutex(ContinuousClock.now)
        let noteOutput: @Sendable () -> Void = { lastOutput.withLock { $0 = .now } }
        async let stdout = readAll(stdoutPipe.read, onLine: onStdoutLine, onOutput: noteOutput)
        async let stderr = readAll(stderrPipe.read, onLine: nil, onOutput: noteOutput)

        let timedOut = Mutex(false)
        let stalled = Mutex(false)
        let timeoutTask = Task {
            let deadline = ContinuousClock.now + request.timeout
            if let idle = request.idleTimeout {
                while ContinuousClock.now < deadline {
                    if ContinuousClock.now - lastOutput.withLock({ $0 }) >= idle {
                        stalled.withLock { $0 = true }
                        break
                    }
                    try await Task.sleep(for: min(.seconds(5), idle / 4, deadline - .now))
                }
            } else {
                try await Task.sleep(for: request.timeout)
            }
            timedOut.withLock { $0 = true }
            terminateGroup(pid)
        }
        let status = await withTaskCancellationHandler {
            await waitForExit(pid)
        } onCancel: {
            terminateGroup(pid)
        }
        timeoutTask.cancel()
        // Anything the child left behind in its group goes too.
        killpg(pid, SIGKILL)
        liveGroups.withLock { _ = $0.remove(pid) }

        let result = ProcessResult(
            termination: decode(status),
            stdout: await stdout,
            stderr: await stderr,
            timedOut: timedOut.withLock { $0 },
            stalled: stalled.withLock { $0 }
        )
        try Task.checkCancellation()
        return result
    }

    /// Kills a process group left over from a previous app session (e.g. after a crash), but
    /// only if one of its processes still looks like `expectedCommand`, so a recycled group ID
    /// can never take down an unrelated program. Returns whether anything was killed.
    @discardableResult
    public static func terminateOrphanedGroup(_ group: pid_t, expectedCommand: String) async -> Bool {
        guard group > 1, group != getpgrp() else { return false }
        let environment = ["PATH": "/usr/bin:/bin"]
        let home = URL(filePath: "/", directoryHint: .isDirectory)
        guard let members = try? await run(ProcessRequest(
            executable: URL(filePath: "/usr/bin/pgrep"), arguments: ["-g", String(group)],
            workingDirectory: home, environment: environment, timeout: .seconds(10)
        )), members.succeeded else { return false }
        let pids = members.stdoutText.split(whereSeparator: \.isNewline).map(String.init)
        guard !pids.isEmpty, let commands = try? await run(ProcessRequest(
            executable: URL(filePath: "/bin/ps"), arguments: ["-o", "command=", "-p", pids.joined(separator: ",")],
            workingDirectory: home, environment: environment, timeout: .seconds(10)
        )), commands.stdoutText.contains(expectedCommand) else { return false }
        return killpg(group, SIGKILL) == 0
    }

    /// Starts a long-running process (e.g. a dev server) in its own process group, unsandboxed,
    /// with stdout and stderr appended to `logURL`. It runs until `terminate()` or app quit.
    public static func start(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String],
        logURL: URL
    ) throws -> BackgroundProcess {
        let path = executable.path
        guard FileManager.default.isExecutableFile(atPath: path) else { throw ProcessRunnerError.notExecutable(path) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workingDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProcessRunnerError.missingWorkingDirectory(workingDirectory.path)
        }
        signal(SIGPIPE, SIG_IGN)
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let log = try FileHandle(forWritingTo: logURL)
        _ = try? log.seekToEnd()

        let stdinPipe = try makePipe(path)
        let outputPipe = try makePipe(path)
        // The user is clicking through these services, so they keep the default QoS.
        let request = ProcessRequest(
            executable: executable, arguments: arguments, workingDirectory: workingDirectory,
            environment: environment, timeout: .seconds(0), qualityOfService: nil
        )
        let pid: pid_t
        do {
            pid = try spawn(request, stdin: stdinPipe.read, stdout: outputPipe.write, stderr: outputPipe.write)
        } catch {
            [stdinPipe.read, stdinPipe.write, outputPipe.read, outputPipe.write].forEach { close($0) }
            try? log.close()
            throw error
        }
        close(stdinPipe.read)
        close(stdinPipe.write)  // No input: the child sees EOF.
        close(outputPipe.write)
        liveGroups.withLock { _ = $0.insert(pid) }

        let process = BackgroundProcess(pid: pid, logURL: logURL)
        let outputFD = outputPipe.read
        DispatchQueue.global().async {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = read(outputFD, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { break }
                try? log.write(contentsOf: Data(buffer[0..<count]))
            }
            close(outputFD)
            try? log.close()
        }
        DispatchQueue.global().async {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            killpg(pid, SIGKILL)  // Anything the service left behind in its group.
            liveGroups.withLock { _ = $0.remove(pid) }
            process.markExited(decode(status))
        }
        return process
    }

    /// Kills a process group left over from a previous app session, identified by when it
    /// started rather than its command line (which `exec` can rewrite): only if the group still
    /// exists, does not include DevPilot itself, and every member started no earlier than
    /// `startedAt` (minus a second of clock slack). A recycled group ID belongs to a newer process
    /// and therefore never matches.
    @discardableResult
    public static func terminateOrphanedGroup(_ group: pid_t, startedAt: Date) async -> Bool {
        guard group > 1, group != getpgrp() else { return false }
        let environment = ["PATH": "/usr/bin:/bin"]
        let root = URL(filePath: "/", directoryHint: .isDirectory)
        guard let members = try? await run(ProcessRequest(
            executable: URL(filePath: "/usr/bin/pgrep"), arguments: ["-g", String(group)],
            workingDirectory: root, environment: environment, timeout: .seconds(10)
        )), members.succeeded else { return false }
        let pids = members.stdoutText.split(whereSeparator: \.isNewline).map(String.init)
        guard !pids.isEmpty, let elapsed = try? await run(ProcessRequest(
            executable: URL(filePath: "/bin/ps"), arguments: ["-o", "etime=", "-p", pids.joined(separator: ",")],
            workingDirectory: root, environment: environment, timeout: .seconds(10)
        )) else { return false }
        let now = Date()
        let starts = elapsed.stdoutText.split(whereSeparator: \.isNewline).compactMap { parseElapsed(String($0)) }.map { now.addingTimeInterval(-$0) }
        guard !starts.isEmpty, starts.allSatisfy({ $0 >= startedAt.addingTimeInterval(-1) }) else { return false }
        return killpg(group, SIGKILL) == 0
    }

    /// `ps` etime: `[[dd-]hh:]mm:ss` → seconds.
    static func parseElapsed(_ text: String) -> TimeInterval? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let dayParts = trimmed.split(separator: "-")
        let days = dayParts.count == 2 ? Double(dayParts[0]) ?? 0 : 0
        let clock = (dayParts.last ?? "").split(separator: ":").compactMap { Double($0) }
        guard (2...3).contains(clock.count) else { return nil }
        let seconds = clock.reversed().enumerated().reduce(0.0) { $0 + $1.element * pow(60, Double($1.offset)) }
        return days * 86_400 + seconds
    }

    // MARK: - Internals

    private static func spawn(_ request: ProcessRequest, stdin: Int32, stdout: Int32, stderr: Int32) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, stdin, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stdout, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderr, STDERR_FILENO)
        posix_spawn_file_actions_addchdir_np(&actions, request.workingDirectory.path)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // New process group; close every descriptor not set up above; reset signal state.
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var noSignals = sigset_t()
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        var allSignals = ~sigset_t()
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        if let qos = request.qualityOfService {
            posix_spawnattr_set_qos_class_np(&attributes, qos)
        }

        let path = request.executable.path
        let argv = ([path] + request.arguments).map { strdup($0) } + [nil]
        let envp = request.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let code = posix_spawn(&pid, path, &actions, &attributes, argv, envp)
        guard code == 0 else { throw ProcessRunnerError.launchFailed(path, errno: code) }
        return pid
    }

    private static func makePipe(_ path: String) throws -> (read: Int32, write: Int32) {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw ProcessRunnerError.launchFailed(path, errno: errno) }
        return (fds[0], fds[1])
    }

    private static func terminateGroup(_ pid: pid_t) {
        guard liveGroups.withLock({ $0.contains(pid) }) else { return }
        killpg(pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(Int(terminationGrace.components.seconds))) {
            if liveGroups.withLock({ $0.contains(pid) }) {
                killpg(pid, SIGKILL)
            }
        }
    }

    private static func waitForExit(_ pid: pid_t) async -> Int32 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var status: Int32 = 0
                while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
                continuation.resume(returning: status)
            }
        }
    }

    private static func decode(_ status: Int32) -> ProcessResult.Termination {
        let signal = status & 0x7f
        return signal == 0 ? .exited((status >> 8) & 0xff) : .signaled(signal)
    }

    private static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { buffer in
            guard var pointer = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = write(fd, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return  // EPIPE: the child stopped reading.
                }
                pointer += written
                remaining -= written
            }
        }
    }

    /// Reads until EOF, keeping at most `maxCapturedBytes` and reporting complete lines as they arrive.
    private static func readAll(_ fd: Int32, onLine: (@Sendable (String) -> Void)?, onOutput: @escaping @Sendable () -> Void) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var captured = Data()
                var pendingLine = Data()
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    let count = read(fd, &buffer, buffer.count)
                    if count < 0 && errno == EINTR { continue }
                    if count <= 0 { break }
                    onOutput()
                    let chunk = buffer[0..<count]
                    if captured.count < maxCapturedBytes {
                        captured.append(contentsOf: chunk.prefix(maxCapturedBytes - captured.count))
                    }
                    if let onLine {
                        pendingLine.append(contentsOf: chunk)
                        while let newline = pendingLine.firstIndex(of: 0x0A) {
                            onLine(String(decoding: pendingLine[pendingLine.startIndex..<newline], as: UTF8.self))
                            pendingLine.removeSubrange(pendingLine.startIndex...newline)
                        }
                    }
                }
                if let onLine, !pendingLine.isEmpty {
                    onLine(String(decoding: pendingLine, as: UTF8.self))
                }
                close(fd)
                continuation.resume(returning: captured)
            }
        }
    }
}

/// A long-running child started by `ProcessRunner.start`.
public final class BackgroundProcess: Sendable {
    public let pid: pid_t
    public let logURL: URL
    private let exit = Mutex<ProcessResult.Termination?>(nil)

    init(pid: pid_t, logURL: URL) {
        self.pid = pid
        self.logURL = logURL
    }

    public var termination: ProcessResult.Termination? { exit.withLock { $0 } }
    public var isRunning: Bool { termination == nil }

    func markExited(_ termination: ProcessResult.Termination) {
        exit.withLock { $0 = termination }
    }

    /// SIGTERM to the whole group, then SIGKILL after `grace`.
    public func terminate(grace: Duration = .seconds(10)) async {
        if isRunning {
            killpg(pid, SIGTERM)
            let deadline = ContinuousClock.now + grace
            while isRunning && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        if isRunning { killpg(pid, SIGKILL) }
        while isRunning { try? await Task.sleep(for: .milliseconds(50)) }
    }

    /// The last lines of the log, for error messages.
    public func logTail(lines: Int = 25) -> String {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return "" }
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }
}
