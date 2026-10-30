import Darwin
import Foundation
import Synchronization
import Testing
@testable import DevPilotCore

struct ProcessRunnerTests {
    let tmp = FileManager.default.temporaryDirectory

    func request(_ executable: String, _ arguments: [String], env: [String: String] = [:], stdin: Data? = nil, timeout: Duration = .seconds(10)) -> ProcessRequest {
        ProcessRequest(
            executable: URL(filePath: executable), arguments: arguments, workingDirectory: tmp,
            environment: env, stdin: stdin, timeout: timeout
        )
    }

    @Test func passesArgumentsVerbatimWithoutShellInterpolation() async throws {
        let result = try await ProcessRunner.run(request("/bin/echo", ["a b", "$HOME", "; rm -rf /", "`id`"]))
        #expect(result.stdoutText == "a b $HOME ; rm -rf / `id`\n")
        #expect(result.succeeded)
    }

    @Test func environmentIsReplacedNotInherited() async throws {
        let result = try await ProcessRunner.run(request("/usr/bin/env", [], env: ["ONLY": "1"]))
        #expect(result.stdoutText == "ONLY=1\n")
    }

    @Test func runsInRequestedDirectory() async throws {
        let result = try await ProcessRunner.run(request("/bin/pwd", []))
        let expected = try #require(realpath(tmp.path, nil).map { String(cString: $0) })
        #expect(result.stdoutText.trimmingCharacters(in: .newlines) == expected)
    }

    @Test func feedsStdin() async throws {
        let result = try await ProcessRunner.run(request("/bin/cat", [], stdin: Data("hello\nworld".utf8)))
        #expect(result.stdoutText == "hello\nworld")
    }

    @Test func reportsExitCodeAndStderr() async throws {
        let result = try await ProcessRunner.run(request("/bin/sh", ["-c", "echo oops >&2; exit 3"]))
        #expect(result.termination == .exited(3))
        #expect(result.stderrText == "oops\n")
        #expect(!result.succeeded)
    }

    @Test func streamsCompleteLines() async throws {
        let lines = Mutex<[String]>([])
        _ = try await ProcessRunner.run(request("/usr/bin/printf", ["one\\ntwo\\nthree"])) { line in
            lines.withLock { $0.append(line) }
        }
        #expect(lines.withLock { $0 } == ["one", "two", "three"])
    }

    @Test func timeoutKillsTheWholeProcessGroup() async throws {
        // The shell starts a grandchild and waits; both must die.
        let started = ContinuousClock.now
        let result = try await ProcessRunner.run(
            request("/bin/sh", ["-c", "sleep 60 & echo $!; wait"], timeout: .milliseconds(500))
        )
        #expect(result.timedOut)
        #expect(ContinuousClock.now - started < .seconds(5))
        let grandchild = try #require(pid_t(result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(await processIsGone(grandchild))
    }

    @Test func cancellationStopsTheProcess() async throws {
        let started = ContinuousClock.now
        let task = Task {
            try await ProcessRunner.run(request("/bin/sleep", ["60"]))
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func rejectsNonExecutables() async {
        await #expect(throws: ProcessRunnerError.notExecutable("/etc/hosts")) {
            _ = try await ProcessRunner.run(request("/etc/hosts", []))
        }
    }

    /// Polls because a killed process may briefly linger before it is reaped.
    private func processIsGone(_ pid: pid_t) async -> Bool {
        for _ in 0..<40 {
            if kill(pid, 0) == -1 && errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
}
