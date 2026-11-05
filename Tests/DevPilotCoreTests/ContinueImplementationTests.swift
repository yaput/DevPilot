import Foundation
import Testing
@testable import DevPilotCore

struct IdleTimeoutTests {
    func sh(_ script: String, timeout: Duration, idle: Duration?) async throws -> ProcessResult {
        try await ProcessRunner.run(ProcessRequest(
            executable: URL(filePath: "/bin/sh"), arguments: ["-c", script], workingDirectory: URL(filePath: "/tmp"),
            environment: ["PATH": "/usr/bin:/bin"], timeout: timeout, idleTimeout: idle
        ))
    }

    @Test func aSilentProcessIsStoppedAsStalled() async throws {
        let started = ContinuousClock.now
        let result = try await sh("sleep 30", timeout: .seconds(30), idle: .milliseconds(400))
        #expect(result.stalled)
        #expect(result.timedOut)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func aBusyProcessOutlivesTheIdleLimit() async throws {
        // Prints every 0.1 s for about 2 s: past a 1 s idle limit, never idle for that long (with
        // room for a loaded machine running the whole suite in parallel).
        let result = try await sh("for i in $(seq 1 20); do echo $i; sleep 0.1; done", timeout: .seconds(20), idle: .seconds(1))
        #expect(!result.timedOut)
        #expect(!result.stalled)
        #expect(result.stdoutText.contains("20"))
    }

    @Test func theOverallLimitStillApplies() async throws {
        let result = try await sh("while true; do echo tick; sleep 0.05; done", timeout: .milliseconds(500), idle: .seconds(10))
        #expect(result.timedOut)
        #expect(!result.stalled)
    }
}

struct ImplementationSessionTests {
    func runner() -> ClaudeCodeRunner {
        ClaudeCodeRunner(executable: URL(filePath: "/bin/claude"), model: nil, investigationTimeout: .seconds(1), implementationTimeout: .seconds(1))
    }

    func request(session: String?, continues: Bool = false, earlier: [String] = []) -> ImplementationRequest {
        ImplementationRequest(
            ticket: .sample(), workspace: .sample(),
            plan: DecisionDocument(ticketID: Ticket.sample().id, version: 1, markdown: "# Plan", createdAt: Date()),
            allowedCommands: [], commonGitDirectory: "/tmp/repo/.git", tools: ToolEnvironment(path: "", javaHome: ""),
            logURL: URL(filePath: "/tmp/x.jsonl"), sessionID: session, continuesSession: continues, earlierChanges: earlier
        )
    }

    func value(after flag: String, in arguments: [String]) -> String? {
        arguments.firstIndex(of: flag).map { arguments[$0 + 1] }
    }

    @Test func implementationsKeepTheirSessionUnderAKnownID() {
        let arguments = runner().implementationArguments(request(session: "1b6f9392-5f95-43bf-b2e4-62b8623dcfab"))
        #expect(value(after: "--session-id", in: arguments) == "1b6f9392-5f95-43bf-b2e4-62b8623dcfab")
        #expect(!arguments.contains("--no-session-persistence"))
        #expect(!arguments.contains("--resume"))
    }

    @Test func continuingResumesThatSession() {
        let arguments = runner().implementationArguments(request(session: "abc", continues: true))
        #expect(value(after: "--resume", in: arguments) == "abc")
        #expect(!arguments.contains("--session-id"))
        #expect(ImplementationPrompt.continuation(request(session: "abc", continues: true)).contains("Continue from where you stopped"))
    }

    @Test func otherAgentsStillKeepNoSession() {
        #expect(runner().investigationArguments(worktree: "/w").contains("--no-session-persistence"))
        #expect(runner().implementationArguments(request(session: nil)).contains("--no-session-persistence"))
    }

    @Test func aFreshAttemptIsToldAboutEarlierWork() {
        let prompt = ImplementationPrompt.render(request(session: "s", earlier: ["app/Foo.tsx"]))
        #expect(prompt.contains("## Earlier work in this worktree"))
        #expect(prompt.contains("- app/Foo.tsx"))
        #expect(!ImplementationPrompt.render(request(session: "s")).contains("Earlier work"))
    }
}

struct ContinueImplementationTests {
    @Test func aStoppedRunCanBeContinuedInItsSession() async throws {
        let fixture = try await ApprovedTicket()
        defer { fixture.repo.remove() }
        var config = fixture.repo.config
        config.setupCommands = [CommandRule(command: "touch setup-ran")]
        let worktree = fixture.worktree

        // First run: edits a file, then is stopped by the time limit.
        let timingOut = FakeAgentRunner(implement: { _ in
            try "half\n".write(to: worktree.appending(path: "half.txt"), atomically: true, encoding: .utf8)
            throw AgentError.timedOut(minutes: 90)
        })
        await #expect(throws: AgentError.timedOut(minutes: 90)) {
            _ = try await fixture.service(timingOut).implement(
                ticketID: fixture.ticket.id, repository: config, tools: ToolEnvironment(path: "", javaHome: "")
            ) { _ in }
        }
        let stopped = try #require(try await fixture.db.runs(ticketID: fixture.ticket.id).last)
        #expect(stopped.outcome == .timedOut)
        let session = try #require(stopped.sessionID)
        #expect(timingOut.implementations.first?.sessionID == session)
        #expect(timingOut.implementations.first?.continuesSession == false)
        #expect(try await fixture.db.state(of: fixture.ticket.id) == .failed)

        // Continue: same session, no setup again.
        try FileManager.default.removeItem(at: worktree.appending(path: "setup-ran"))
        try await fixture.db.returnToApprovedPlan(ticketID: fixture.ticket.id)
        let continuing = FakeAgentRunner()
        _ = try await fixture.service(continuing).implement(
            ticketID: fixture.ticket.id, repository: config, tools: ToolEnvironment(path: "", javaHome: ""), continuing: session
        ) { _ in }
        let request = try #require(continuing.implementations.first)
        #expect(request.sessionID == session)
        #expect(request.continuesSession)
        #expect(!FileManager.default.fileExists(atPath: worktree.appending(path: "setup-ran").path))
        #expect(try await fixture.db.runs(ticketID: fixture.ticket.id).last?.sessionID == session)
        #expect(try await fixture.db.state(of: fixture.ticket.id) == .validating)
    }

    @Test func aRetryWithoutTheSessionBuildsOnTheWorktree() async throws {
        let fixture = try await ApprovedTicket()
        defer { fixture.repo.remove() }
        try "half\n".write(to: fixture.worktree.appending(path: "half.txt"), atomically: true, encoding: .utf8)
        let runner = FakeAgentRunner()
        _ = try await fixture.service(runner).implement(
            ticketID: fixture.ticket.id, repository: fixture.repo.config, tools: ToolEnvironment(path: "", javaHome: "")
        ) { _ in }
        #expect(runner.implementations.first?.earlierChanges == ["half.txt"])
    }
}

struct ImplementationLimitMigrationTests {
    @Test func theOldThirtyMinuteDefaultBecomesTheNewCap() throws {
        let old = try JSONDecoder().decode(AgentSettings.self, from: Data(#"{"implementationTimeoutMinutes": 30}"#.utf8))
        #expect(old.implementationTimeoutMinutes == 90)

        let chosen = try JSONDecoder().decode(AgentSettings.self, from: Data(#"{"implementationTimeoutMinutes": 45}"#.utf8))
        #expect(chosen.implementationTimeoutMinutes == 45)

        // Chosen after the change: kept, including 30.
        let recent = try JSONDecoder().decode(AgentSettings.self, from: Data(#"{"implementationTimeoutMinutes": 30, "limitsVersion": 2}"#.utf8))
        #expect(recent.implementationTimeoutMinutes == 30)
        #expect(AgentSettings().implementationTimeoutMinutes == 90)
    }
}
