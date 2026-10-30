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

    public init(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String],
        stdin: Data? = nil,
        timeout: Duration,
        onLaunch: (@Sendable (pid_t) -> Void)? = nil
    ) {
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

        async let stdout = readAll(stdoutPipe.read, onLine: onStdoutLine)
        async let stderr = readAll(stderrPipe.read, onLine: nil)

        let timedOut = Mutex(false)
        let timeoutTask = Task {
            try await Task.sleep(for: request.timeout)
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
            timedOut: timedOut.withLock { $0 }
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
    private static func readAll(_ fd: Int32, onLine: (@Sendable (String) -> Void)?) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var captured = Data()
                var pendingLine = Data()
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    let count = read(fd, &buffer, buffer.count)
                    if count < 0 && errno == EINTR { continue }
                    if count <= 0 { break }
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
