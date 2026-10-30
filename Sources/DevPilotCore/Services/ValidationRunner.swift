import Foundation

/// macOS Seatbelt profile for running validation commands on agent-written code. Verified with
/// real runs: writes outside the worktree, temp folders and build caches are denied; the git
/// metadata is read-only (so `git commit` fails); credential stores and shell profiles are
/// unreadable; the internet is unreachable while localhost works (test servers, Gradle daemon).
///
/// Unix sockets are limited to the temp folders (JVM attach, which Mockito needs) and macOS's
/// DNS service. Any other socket, such as Docker's, would be a way out of the sandbox.
enum SeatbeltProfile {
    static let temporaryFolders = ["/private/tmp", "/private/var/folders"]

    static func make(worktree: String, commonGitDirectory: String, home: String) -> String {
        let writable = [worktree] + temporaryFolders
            + SandboxPolicy.cacheDirectories(home: home) + ["\(home)/Library/Caches"]
        func sockets(_ side: String) -> String {
            temporaryFolders.map { "(\(side) unix-socket (subpath \(quote($0))))" }.joined(separator: " ")
        }
        return """
            (version 1)
            (allow default)
            (deny network*)
            (allow network-bind (local ip "localhost:*"))
            (allow network-inbound (local ip "localhost:*"))
            (allow network-outbound (remote ip "localhost:*"))
            (allow network-outbound (remote unix-socket (path-literal "/private/var/run/mDNSResponder")))
            (allow network-bind \(sockets("local")))
            (allow network-inbound \(sockets("local")))
            (allow network-outbound \(sockets("remote")))
            (deny file-write*)
            (allow file-write* \(writable.map { "(subpath \(quote($0)))" }.joined(separator: " ")) (literal "/dev/null") (literal "/dev/tty") (regex #"^/dev/fd/"))
            (deny file-write* (subpath \(quote(commonGitDirectory))) (literal \(quote(worktree + "/.git"))))
            (deny file-read* \(SandboxPolicy.secretPaths(home: home).map { "(subpath \(quote($0)))" }.joined(separator: " ")))
            """
    }

    /// SBPL string literal.
    static func quote(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Runs the repository's validation commands in the worktree, each inside the Seatbelt
/// sandbox, and records exit codes and full logs.
public struct ValidationRunner: Sendable {
    static let sandboxExec = URL(filePath: "/usr/bin/sandbox-exec")
    static let tailLines = 60

    private let timeoutPerCommand: Duration

    public init(timeoutPerCommand: Duration) {
        self.timeoutPerCommand = timeoutPerCommand
    }

    public func run(
        commands: [String],
        worktree: String,
        commonGitDirectory: String,
        tools: ToolEnvironment,
        logDirectory: URL,
        fixAttempt: Int,
        onProgress: @escaping @Sendable (String) -> Void,
        onLaunch: (@Sendable (pid_t) -> Void)? = nil
    ) async throws -> ValidationResult {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let profileURL = logDirectory.appending(path: "validation.sb")
        try SeatbeltProfile.make(
            worktree: GitWorktreeManager.realPath(worktree),
            commonGitDirectory: GitWorktreeManager.realPath(commonGitDirectory),
            home: home
        ).write(to: profileURL, atomically: true, encoding: .utf8)

        var results: [ValidationCommandResult] = []
        for (index, command) in commands.enumerated() {
            onProgress("Running `\(command)`")
            let started = ContinuousClock.now
            let output = try await ProcessRunner.run(ProcessRequest(
                executable: Self.sandboxExec,
                arguments: ["-f", profileURL.path, "/bin/sh", "-c", command],
                workingDirectory: URL(filePath: worktree, directoryHint: .isDirectory),
                environment: tools.variables(base: ClaudeCodeRunner.environment()),
                timeout: timeoutPerCommand,
                onLaunch: onLaunch
            ))
            let elapsed = ContinuousClock.now - started
            let text = output.stdoutText + (output.stderrText.isEmpty ? "" : "\n" + output.stderrText)
            let logURL = logDirectory.appending(path: "command-\(index + 1).log")
            try? "$ \(command)\n\n\(text)".write(to: logURL, atomically: true, encoding: .utf8)
            let exitCode: Int32? = if case .exited(let code) = output.termination, !output.timedOut { code } else { nil }
            let result = ValidationCommandResult(
                command: command,
                exitCode: exitCode,
                timedOut: output.timedOut,
                durationSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
                logPath: logURL.path,
                outputTail: text.split(separator: "\n", omittingEmptySubsequences: false).suffix(Self.tailLines).joined(separator: "\n")
            )
            onProgress("\(result.passed ? "Passed" : "Failed"): `\(command)`")
            results.append(result)
        }
        return ValidationResult(commands: results, fixAttempt: fixAttempt)
    }
}
