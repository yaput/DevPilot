import Foundation
import Synchronization
import Testing
@testable import DevPilotCore

/// Real sandbox-exec runs. The repository lives under HOME because the profile deliberately
/// allows writes to temp folders.
struct ValidationSandboxTests {
    func run(_ commands: [String], in repo: TestRepository, timeout: Duration = .seconds(60)) async throws -> (ValidationResult, TicketWorkspace) {
        let workspace = try await repo.manager.prepareWorktree(for: .sample(), repository: repo.config)
        let result = try await ValidationRunner(timeoutPerCommand: timeout).run(
            commands: commands,
            worktree: workspace.worktreePath,
            commonGitDirectory: try await repo.manager.commonGitDirectory(of: workspace.worktreePath),
            tools: ToolEnvironment(path: ProcessInfo.processInfo.environment["PATH"] ?? "", javaHome: ""),
            logDirectory: repo.root.appending(path: "logs"),
            fixAttempt: 0,
            onProgress: { _ in }
        )
        return (result, workspace)
    }

    @Test func sharedBuildGateKeepsTicketsFromBuildingAtOnce() async throws {
        let repo = try await TestRepository(base: URL(filePath: NSHomeDirectory()))
        defer { repo.remove() }
        let workspace = try await repo.manager.prepareWorktree(for: .sample(), repository: repo.config)
        let common = try await repo.manager.commonGitDirectory(of: workspace.worktreePath)
        let gate = BuildGate(limit: 1, pressure: { .normal })
        let waited = Mutex(false)
        let started = ContinuousClock.now
        // Two tickets' validations, each one 0.4 s command, through one build slot.
        try await withThrowingTaskGroup(of: ValidationResult.self) { group in
            for index in 0..<2 {
                group.addTask {
                    try await ValidationRunner(timeoutPerCommand: .seconds(30), buildGate: gate).run(
                        commands: ["sleep 0.4"], worktree: workspace.worktreePath, commonGitDirectory: common,
                        tools: ToolEnvironment(path: ProcessInfo.processInfo.environment["PATH"] ?? "", javaHome: ""),
                        logDirectory: repo.root.appending(path: "logs-\(index)"), fixAttempt: 0,
                        onProgress: { if $0.hasPrefix("Waiting for a free build slot") { waited.withLock { $0 = true } } }
                    )
                }
            }
            for try await result in group { #expect(result.passed) }
        }
        #expect(ContinuousClock.now - started >= .milliseconds(800))
        #expect(waited.withLock { $0 })
    }

    @Test func commandsSeeWhatTheTicketChanged() async throws {
        let repo = try await TestRepository(base: URL(filePath: NSHomeDirectory()))
        defer { repo.remove() }
        let workspace = try await repo.manager.prepareWorktree(for: .sample(), repository: repo.config)
        try "new\n".write(to: URL(filePath: workspace.worktreePath).appending(path: "added.txt"), atomically: true, encoding: .utf8)
        let changed = try await repo.manager.changedFiles(in: workspace.worktreePath)
        let result = try await ValidationRunner(timeoutPerCommand: .seconds(30)).run(
            commands: [#"test "$DEVPILOT_CHANGED_FILES" = "added.txt" && test "$DEVPILOT_BASE_COMMIT" = "\#(workspace.baseCommit)""#],
            worktree: workspace.worktreePath,
            commonGitDirectory: try await repo.manager.commonGitDirectory(of: workspace.worktreePath),
            tools: ToolEnvironment(path: ProcessInfo.processInfo.environment["PATH"] ?? "", javaHome: ""),
            logDirectory: repo.root.appending(path: "logs"), fixAttempt: 0,
            environment: ValidationRunner.changeEnvironment(baseCommit: workspace.baseCommit, changedFiles: changed),
            onProgress: { _ in }
        )
        #expect(result.passed, "\(result.commands.first?.outputTail ?? "")")
    }

    @Test func recordsExitCodesLogsAndTails() async throws {
        let repo = try await TestRepository(base: URL(filePath: NSHomeDirectory()))
        defer { repo.remove() }
        let (result, _) = try await run(["echo all good", "echo broken >&2; exit 3"], in: repo)

        #expect(result.commands.map(\.exitCode) == [0, 3])
        #expect(!result.passed)
        #expect(result.failed.map(\.command) == ["echo broken >&2; exit 3"])
        #expect(result.commands[1].outputTail.contains("broken"))
        #expect(try String(contentsOf: URL(filePath: result.commands[0].logPath), encoding: .utf8).contains("all good"))
    }

    @Test func agentWrittenCodeCannotEscapeTheWorktree() async throws {
        let repo = try await TestRepository(base: URL(filePath: NSHomeDirectory()))
        defer { repo.remove() }
        let outside = repo.root.appending(path: "outside.txt").path
        let (result, workspace) = try await run([
            "touch inside.txt",
            "touch '\(outside)'",
            "git add -A && git -c user.email=a@b -c user.name=x commit -qm sneaky",
            "echo 'gitdir: /tmp/elsewhere' > .git",
            "/usr/bin/curl -sS -m 5 https://example.com -o /dev/null",
        ], in: repo)

        #expect(result.commands.map(\.passed) == [true, false, false, false, false])
        #expect(FileManager.default.fileExists(atPath: URL(filePath: workspace.worktreePath).appending(path: "inside.txt").path))
        #expect(!FileManager.default.fileExists(atPath: outside))
        #expect(try await repo.git("rev-parse", "HEAD", in: URL(filePath: workspace.worktreePath)) == workspace.baseCommit)
        #expect(try String(contentsOf: URL(filePath: workspace.worktreePath).appending(path: ".git"), encoding: .utf8).hasPrefix("gitdir: \(repo.repo.path)"))
    }

    @Test func localhostWorksForTestServers() async throws {
        let repo = try await TestRepository(base: URL(filePath: NSHomeDirectory()))
        defer { repo.remove() }
        let script = "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); s.listen(1); c=socket.create_connection(s.getsockname()); print('ok')"
        let (result, _) = try await run(["/usr/bin/python3 -c \"\(script)\""], in: repo)
        #expect(result.passed, "\(result.commands.first?.outputTail ?? "")")
    }

    @Test func timeoutFailsTheCommand() async throws {
        let repo = try await TestRepository(base: URL(filePath: NSHomeDirectory()))
        defer { repo.remove() }
        let (result, _) = try await run(["sleep 30"], in: repo, timeout: .milliseconds(500))
        #expect(result.commands.first?.timedOut == true)
        #expect(result.commands.first?.exitCode == nil)
    }

    @Test func profileDeniesSecretsAndQuotesPaths() {
        let profile = SeatbeltProfile.make(worktree: "/Users/x/wt \"q\"", commonGitDirectory: "/Users/x/repo/.git", home: "/Users/x")
        #expect(profile.contains(#"(subpath "/Users/x/.ssh")"#))
        #expect(profile.contains(#"(subpath "/Users/x/.zshrc")"#))
        #expect(profile.contains(#"(subpath "/Users/x/wt \"q\"")"#))
        #expect(profile.contains("(deny network*)"))
        #expect(!profile.contains(#"(allow network* (local"#), "that form also allows outbound internet connections")
        #expect(!profile.contains("(remote unix-socket))"), "an unrestricted unix-socket rule would expose e.g. Docker's socket")
    }

    @Test func otherUnixSocketsAreUnreachable() async throws {
        let repo = try await TestRepository(base: URL(filePath: NSHomeDirectory()))
        defer { repo.remove() }
        // A "Docker-like" socket outside the temp folders, served outside the sandbox.
        let socketPath = repo.root.appending(path: "fake-docker.sock").path
        let server = try await startSocketServer(at: socketPath)
        defer { server.cancel() }
        let (result, _) = try await run(["/usr/bin/python3 -c \"import socket; s=socket.socket(socket.AF_UNIX); s.connect('\(socketPath)')\""], in: repo)
        #expect(!result.passed)
        #expect(result.commands.first?.outputTail.contains("Operation not permitted") == true)
    }

    @Test(.enabled(if: ValidationSandboxTests.javaHome != nil))
    func jvmAttachWorksForMockito() async throws {
        let repo = try await TestRepository(files: [
            "Attach.java": """
                import com.sun.tools.attach.VirtualMachine;
                public class Attach { public static void main(String[] a) throws Exception {
                  VirtualMachine.attach(String.valueOf(ProcessHandle.current().pid())).detach(); System.out.println("attached"); } }
                """,
        ], base: URL(filePath: NSHomeDirectory()))
        defer { repo.remove() }
        let java = try #require(Self.javaHome) + "/bin"
        let (result, _) = try await run(["'\(java)/javac' Attach.java && '\(java)/java' -Djdk.attach.allowAttachSelf=true -cp . Attach"], in: repo)
        #expect(result.passed, "\(result.commands.first?.outputTail ?? "")")
    }

    static var javaHome: String? {
        if let home = ProcessInfo.processInfo.environment["JAVA_HOME"], FileManager.default.fileExists(atPath: home + "/bin/javac") { return home }
        return nil
    }

    /// Listens on a Unix socket for the duration of a test.
    private func startSocketServer(at path: String) async throws -> Task<Void, Never> {
        let task = Task {
            _ = try? await ProcessRunner.run(ProcessRequest(
                executable: URL(filePath: "/usr/bin/python3"),
                arguments: ["-c", "import socket,time; s=socket.socket(socket.AF_UNIX); s.bind('\(path)'); s.listen(5); time.sleep(30)"],
                workingDirectory: URL(filePath: "/"), environment: [:], timeout: .seconds(40)
            ))
        }
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: path) {
            try await Task.sleep(for: .milliseconds(100))
        }
        return task
    }
}

/// Drives a ticket through approval and implementation, to `validating`.
struct ImplementedTicket {
    let fixture: ApprovedTicket
    let tools = ToolEnvironment(path: ProcessInfo.processInfo.environment["PATH"] ?? "", javaHome: "")

    init(base: URL = FileManager.default.temporaryDirectory) async throws {
        fixture = try await ApprovedTicket()
        _ = try await fixture.service(FakeAgentRunner()).implement(
            ticketID: fixture.ticket.id, repository: fixture.repo.config, tools: tools
        ) { _ in }
    }

    func verification(_ runner: FakeAgentRunner) -> VerificationService {
        VerificationService(
            database: fixture.db, worktrees: fixture.repo.manager, runner: runner,
            implementation: fixture.service(runner), validationTimeout: .seconds(60), artifacts: fixture.artifacts
        )
    }

    func repository(_ validation: [String]) -> RepositoryConfig {
        var config = fixture.repo.config
        config.validationCommands = validation.map { CommandRule(command: $0) }
        return config
    }

    var id: String { fixture.ticket.id }
    var db: AppDatabase { fixture.db }
}

struct VerificationServiceTests {
    @Test func passingValidationThenReviewHandsOff() async throws {
        let ticket = try await ImplementedTicket()
        defer { ticket.fixture.repo.remove() }
        let runner = FakeAgentRunner()

        let report = try await ticket.verification(runner).verify(
            ticketID: ticket.id, repository: ticket.repository(["true"]), tools: ticket.tools, maxFixAttempts: 1
        ) { _ in }

        #expect(report == .sample())
        #expect(try await ticket.db.state(of: ticket.id) == .readyForHumanReview)
        let runs = try await ticket.db.runs(ticketID: ticket.id)
        #expect(runs.map(\.kind).suffix(2) == [.validation, .review])
        #expect(runs.first { $0.kind == .validation }?.validation?.passed == true)
        #expect(runs.last?.review == .sample())
        let request = try #require(runner.reviews.first)
        #expect(request.validation.passed)
        #expect(request.implementation == .sample())
        let reviewFile = URL(filePath: try #require(runs.last?.logPath)).deletingPathExtension().appendingPathExtension("md")
        #expect(try String(contentsOf: reviewFile, encoding: .utf8).contains("Verdict: **Approve**"))
    }

    @Test func failingValidationGetsBoundedAutomaticFix() async throws {
        let ticket = try await ImplementedTicket()
        defer { ticket.fixture.repo.remove() }
        let worktree = ticket.fixture.worktree
        let runner = FakeAgentRunner(implement: { request in
            // The "fix": make the failing check pass.
            if request.fixInstructions != nil {
                try "fixed\n".write(to: worktree.appending(path: "fixed.txt"), atomically: true, encoding: .utf8)
            }
            return .sample()
        })

        _ = try await ticket.verification(runner).verify(
            ticketID: ticket.id, repository: ticket.repository(["test -f fixed.txt"]), tools: ticket.tools, maxFixAttempts: 2
        ) { _ in }

        #expect(runner.implementations.count == 1)
        #expect(runner.implementations.first?.fixInstructions?.contains("`test -f fixed.txt` (exit 1)") == true)
        let validations = try await ticket.db.runs(ticketID: ticket.id).compactMap(\.validation)
        #expect(validations.map(\.passed) == [false, true])
        #expect(validations.map(\.fixAttempt) == [0, 1])
        #expect(try await ticket.db.state(of: ticket.id) == .readyForHumanReview)
    }

    @Test func stillFailingAfterAttemptsIsReviewedAndFlaggedNotHidden() async throws {
        let ticket = try await ImplementedTicket()
        defer { ticket.fixture.repo.remove() }
        let runner = FakeAgentRunner()

        _ = try await ticket.verification(runner).verify(
            ticketID: ticket.id, repository: ticket.repository(["exit 1"]), tools: ticket.tools, maxFixAttempts: 1
        ) { _ in }

        #expect(runner.implementations.count == 1)
        #expect(runner.reviews.first?.validation.passed == false)
        #expect(try await ticket.db.state(of: ticket.id) == .readyForHumanReview)
        #expect(try await ticket.db.runs(ticketID: ticket.id).compactMap(\.validation).last?.passed == false)
    }

    @Test func noAutomaticFixWhenDisabled() async throws {
        let ticket = try await ImplementedTicket()
        defer { ticket.fixture.repo.remove() }
        let runner = FakeAgentRunner()
        _ = try await ticket.verification(runner).verify(
            ticketID: ticket.id, repository: ticket.repository(["exit 1"]), tools: ticket.tools, maxFixAttempts: 0
        ) { _ in }
        #expect(runner.implementations.isEmpty)
    }

    @Test func failedReviewRestsInReviewingAndCanBeRerun() async throws {
        let ticket = try await ImplementedTicket()
        defer { ticket.fixture.repo.remove() }
        let failing = FakeAgentRunner(review: { _ in throw AgentError.failed("overloaded") })

        await #expect(throws: AgentError.failed("overloaded")) {
            try await ticket.verification(failing).verify(
                ticketID: ticket.id, repository: ticket.repository([]), tools: ticket.tools, maxFixAttempts: 0
            ) { _ in }
        }
        #expect(try await ticket.db.state(of: ticket.id) == .reviewing)
        #expect(try await ticket.db.runs(ticketID: ticket.id).last?.outcome == .failed)

        let runner = FakeAgentRunner()
        _ = try await ticket.verification(runner).verify(
            ticketID: ticket.id, repository: ticket.repository(["exit 1"]), tools: ticket.tools, maxFixAttempts: 0
        ) { _ in }
        #expect(try await ticket.db.state(of: ticket.id) == .readyForHumanReview)
        #expect(runner.reviews.count == 1, "review only: validation is not re-run from reviewing")
    }

    @Test func userRequestedFixFromHandOffThenVerifyAgain() async throws {
        let ticket = try await ImplementedTicket()
        defer { ticket.fixture.repo.remove() }
        let runner = FakeAgentRunner()
        let verification = ticket.verification(runner)
        _ = try await verification.verify(ticketID: ticket.id, repository: ticket.repository([]), tools: ticket.tools, maxFixAttempts: 0) { _ in }

        _ = try await ticket.fixture.service(runner).implement(
            ticketID: ticket.id, repository: ticket.repository([]), tools: ticket.tools, fixInstructions: "Rename retry() to retryDelivery()"
        ) { _ in }
        #expect(try await ticket.db.state(of: ticket.id) == .validating)
        _ = try await verification.verify(ticketID: ticket.id, repository: ticket.repository([]), tools: ticket.tools, maxFixAttempts: 0) { _ in }

        #expect(try await ticket.db.state(of: ticket.id) == .readyForHumanReview)
        #expect(runner.implementations.last?.fixInstructions == "Rename retry() to retryDelivery()")
        #expect(runner.reviews.count == 2)
    }

    @Test func handOffCanBeVerifiedAgainAndMarkedDone() async throws {
        let ticket = try await ImplementedTicket()
        defer { ticket.fixture.repo.remove() }
        let verification = ticket.verification(FakeAgentRunner())
        _ = try await verification.verify(ticketID: ticket.id, repository: ticket.repository([]), tools: ticket.tools, maxFixAttempts: 0) { _ in }
        _ = try await verification.verify(ticketID: ticket.id, repository: ticket.repository(["true"]), tools: ticket.tools, maxFixAttempts: 0) { _ in }
        #expect(try await ticket.db.runs(ticketID: ticket.id).compactMap(\.validation).count == 2)

        try await ticket.db.markDone(ticketID: ticket.id)
        #expect(try await ticket.db.state(of: ticket.id) == .completeManual)
    }

    @Test func crashDuringValidationIsRecovered() async throws {
        let ticket = try await ImplementedTicket()
        defer { ticket.fixture.repo.remove() }
        _ = try await ticket.db.beginVerificationRun(.validation, ticketID: ticket.id, in: .validating, logPath: "/tmp/x")

        let interrupted = try await ticket.db.failInterruptedRuns(message: "Interrupted")

        #expect(interrupted == [ticket.id])
        #expect(try await ticket.db.state(of: ticket.id) == .failed)
        #expect(try await ticket.db.runs(ticketID: ticket.id).last?.outcome == .interrupted)
    }

    @Test func secondVerificationRunIsRefused() async throws {
        let ticket = try await ImplementedTicket()
        defer { ticket.fixture.repo.remove() }
        _ = try await ticket.db.beginVerificationRun(.validation, ticketID: ticket.id, in: .validating, logPath: "/tmp/x")
        await #expect(throws: WorkflowError.self) {
            _ = try await ticket.db.beginVerificationRun(.validation, ticketID: ticket.id, in: .validating, logPath: "/tmp/y")
        }
    }

    @Test func fixRequiresTheApprovalToStillHold() async throws {
        let ticket = try await ImplementedTicket()
        defer { ticket.fixture.repo.remove() }
        try await ticket.db.transition(ticketID: ticket.id, to: .cancelled, message: "")
        await #expect(throws: WorkflowError.implementationBlocked(.wrongState(.cancelled))) {
            _ = try await ticket.db.beginFix(ticketID: ticket.id, logPath: "/tmp/x", reason: "fix")
        }
    }
}

struct ReviewAgentTests {
    func request(worktree: String = "/w/t") -> ReviewRequest {
        ReviewRequest(
            ticket: .sample(), workspace: .sample(worktree: worktree),
            plan: DecisionDocument(ticketID: Ticket.sample().id, version: 3, markdown: "# Plan v3", createdAt: Date()),
            implementation: .sample(), validation: ValidationResult(commands: [
                ValidationCommandResult(command: "pnpm test", exitCode: 1, timedOut: false, durationSeconds: 3, logPath: "/x", outputTail: "FAIL retry.test.ts"),
            ], fixAttempt: 1),
            diff: "diff --git a/x b/x\n+new line", commonGitDirectory: "/repo/.git", logURL: URL(filePath: "/tmp/r.jsonl")
        )
    }

    @Test func reviewIsReadOnly() {
        let arguments = ClaudeCodeRunner(executable: URL(filePath: "/bin/claude"), model: nil, investigationTimeout: .seconds(1), implementationTimeout: .seconds(1))
            .reviewArguments(request())
        let allowed = Array(arguments[(arguments.firstIndex(of: "--allowedTools")! + 1)...].prefix { !$0.hasPrefix("--") })
        #expect(allowed.first == "Read(//w/t/**)")
        let readOnlyShell = Set((CommandPresets.gitInspection + CommandPresets.shellUtilities).map { "Bash(\($0):*)" })
        #expect(Set(allowed.dropFirst()) == readOnlyShell)
        #expect(!allowed.contains { $0.hasPrefix("Edit") || $0.hasPrefix("Write") })
        #expect(arguments.contains("--settings"))
    }

    @Test func promptCarriesPlanFailuresAndDiff() {
        let prompt = ReviewPrompt.render(request())
        #expect(prompt.contains("<approved_plan version=\"3\">\n# Plan v3"))
        #expect(prompt.contains("`pnpm test`: FAILED (exit 1)"))
        #expect(prompt.contains("FAIL retry.test.ts"))
        #expect(prompt.contains("+new line"))
        #expect(prompt.contains("Implementer's report (unverified)"))
    }

    @Test func schemaIsValidJSON() throws {
        let schema = try JSONDecoder().decode(JSONValue.self, from: Data(ReviewPrompt.schema.utf8))
        #expect(schema["required"]?.array?.count == 6)
    }

    @Test func reviewOverFakeCLI() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "devpilot-review-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let finding = ReviewReport.Finding(severity: .major, category: .missingTest, file: "src/a.ts", line: 12, title: "No test", detail: "d", suggestion: "s")
        let report = String(decoding: try JSONEncoder().encode(ReviewReport.sample(verdict: .changesRequested, findings: [finding])), as: UTF8.self)
        let fake = try FakeClaude(body: #"echo '{"type":"result","subtype":"success","is_error":false,"num_turns":4,"structured_output":\#(report)}'"#)
        defer { fake.remove() }
        let runner = ClaudeCodeRunner(executable: fake.executable, model: nil, investigationTimeout: .seconds(10), implementationTimeout: .seconds(10))

        let (parsed, _) = try await runner.review(request(worktree: directory.path)) { _ in }

        #expect(parsed.verdict == .changesRequested)
        #expect(parsed.findings == [finding])
    }

    @Test func reviewDocumentListsFindingsBySeverity() {
        let findings = [
            ReviewReport.Finding(severity: .nit, category: .quality, file: "a.ts", line: 0, title: "Naming", detail: "d", suggestion: ""),
            ReviewReport.Finding(severity: .critical, category: .security, file: "b.ts", line: 7, title: "SQL injection", detail: "d", suggestion: "Use parameters"),
        ]
        let markdown = ReviewDocumentRenderer.render(
            .sample(verdict: .changesRequested, findings: findings), validation: request().validation,
            ticket: .sample(), workspace: .sample(), planVersion: 3
        )
        #expect(markdown.contains("Verdict: **Changes requested**"))
        #expect(markdown.contains("- Tests: 1 failing"))
        let critical = try! #require(markdown.range(of: "**CRITICAL** (security) `b.ts:7`: SQL injection"))
        let nit = try! #require(markdown.range(of: "**NIT**"))
        #expect(critical.lowerBound < nit.lowerBound)
    }
}

struct BranchStatusTests {
    @Test func countsCommitsAndUpstream() async throws {
        let fixture = try await ApprovedTicket()
        defer { fixture.repo.remove() }
        let worktree = fixture.worktree
        #expect(try #require(await fixture.repo.manager.branchStatus(fixture.workspace)).commitsSinceBase == 0)

        try "x\n".write(to: worktree.appending(path: "x.txt"), atomically: true, encoding: .utf8)
        try await fixture.repo.git("add", "-A", in: worktree)
        try await fixture.repo.git("-c", "user.email=a@b", "-c", "user.name=u", "commit", "-qm", "x", in: worktree)
        try "y\n".write(to: worktree.appending(path: "y.txt"), atomically: true, encoding: .utf8)

        let status = try #require(await fixture.repo.manager.branchStatus(fixture.workspace))
        #expect(status.commitsSinceBase == 1)
        #expect(status.upstream == nil)
        #expect(status.unpushedCommits == 1)
        #expect(status.uncommittedFiles == 1)
    }
}

struct StartOverTests {
    func service(_ ticket: ImplementedTicket) -> StartOverService {
        StartOverService(database: ticket.db, worktrees: ticket.fixture.repo.manager, artifacts: ticket.fixture.artifacts)
    }

    @Test func cleanSlateFromValidating() async throws {
        let ticket = try await ImplementedTicket()
        defer { ticket.fixture.repo.remove() }
        let workspace = ticket.fixture.workspace
        try "uncommitted\n".write(to: ticket.fixture.worktree.appending(path: "wip.txt"), atomically: true, encoding: .utf8)
        let artifactsFolder = ticket.fixture.artifacts.directory(for: ticket.id)
        #expect(FileManager.default.fileExists(atPath: artifactsFolder.path), "runs wrote transcripts")

        try await service(ticket).startOver(ticketID: ticket.id)

        #expect(!FileManager.default.fileExists(atPath: workspace.worktreePath))
        #expect(!FileManager.default.fileExists(atPath: artifactsFolder.path), "transcripts and logs deleted")
        #expect(try await ticket.db.state(of: ticket.id) == .selected)
        #expect(try await ticket.db.workspace(ticketID: ticket.id) == nil)
        #expect(try await ticket.db.latestDecisionDocument(ticketID: ticket.id) == nil)
        #expect(try await ticket.db.latestApproval(ticketID: ticket.id) == nil)
        #expect(try await ticket.db.runs(ticketID: ticket.id).isEmpty)
        #expect(try await ticket.db.guidance(ticketID: ticket.id).isEmpty)
        #expect(try await ticket.db.events(ticketID: ticket.id).map(\.message) == [
            "Started over (attempt 2): fresh worktree, no earlier plans or answers",
        ])
        #expect(try await ticket.db.implementationGate(ticketID: ticket.id) == .blocked(.wrongState(.selected)))
    }

    @Test func nextInvestigationStartsFreshAtPlanV1() async throws {
        let ticket = try await ImplementedTicket()
        defer { ticket.fixture.repo.remove() }
        try await ticket.db.recordClarificationForTest(ticketID: ticket.id)
        try await service(ticket).startOver(ticketID: ticket.id)
        let runner = FakeAgentRunner()

        let plan = try await InvestigationService(
            database: ticket.db, worktrees: ticket.fixture.repo.manager, runner: runner, artifacts: ticket.fixture.artifacts
        ).investigate(ticketID: ticket.id, repository: ticket.fixture.repo.config) { _ in }

        #expect(plan.version == 1)
        let request = try #require(runner.requests.first)
        #expect(request.previousPlan == nil)
        #expect(request.guidance.isEmpty)
        let fresh = try #require(try await ticket.db.workspace(ticketID: ticket.id))
        #expect(FileManager.default.fileExists(atPath: fresh.worktreePath))
        #expect(try await ticket.db.state(of: ticket.id) == .awaitingPlanApproval)
    }

    @Test func olderAttemptsStayInTheDatabaseAsAuditTrail() async throws {
        let ticket = try await ImplementedTicket()
        defer { ticket.fixture.repo.remove() }
        try await service(ticket).startOver(ticketID: ticket.id)
        let archived = try await ticket.db.rowCountForTest(table: "agentRun", ticketID: ticket.id)
        #expect(archived >= 2, "the first attempt's investigation and implementation runs are kept")
    }

    @Test func refusedWhileRunning() async throws {
        let ticket = try await ImplementedTicket()
        defer { ticket.fixture.repo.remove() }
        _ = try await ticket.db.beginVerificationRun(.validation, ticketID: ticket.id, in: .validating, logPath: "/tmp/x")
        await #expect(throws: (any Error).self) {
            try await service(ticket).startOver(ticketID: ticket.id)
        }
    }
}

struct PushStatusTests {
    /// A ticket branch with one commit, plus a bare "origin" to push to.
    func committedBranch() async throws -> (ApprovedTicket, URL) {
        let fixture = try await ApprovedTicket()
        let worktree = fixture.worktree
        try "x\n".write(to: worktree.appending(path: "x.txt"), atomically: true, encoding: .utf8)
        try await fixture.repo.git("add", "-A", in: worktree)
        try await fixture.repo.git("-c", "user.email=a@b", "-c", "user.name=u", "commit", "-qm", "x", in: worktree)
        let origin = fixture.repo.root.appending(path: "origin.git", directoryHint: .isDirectory)
        try await fixture.repo.git("init", "-q", "--bare", origin.path, in: fixture.repo.root)
        try await fixture.repo.git("remote", "add", "origin", origin.path)
        return (fixture, worktree)
    }

    @Test func pushedWithUpstream() async throws {
        let (fixture, worktree) = try await committedBranch()
        defer { fixture.repo.remove() }
        try await fixture.repo.git("push", "-q", "-u", "origin", fixture.workspace.branch, in: worktree)

        let status = try #require(await fixture.repo.manager.branchStatus(fixture.workspace))
        #expect(status.upstream == "origin/\(fixture.workspace.branch)")
        #expect(status.unpushedCommits == 0)
    }

    @Test func pushedWithoutUpstreamIsStillRecognised() async throws {
        let (fixture, worktree) = try await committedBranch()
        defer { fixture.repo.remove() }
        try await fixture.repo.git("push", "-q", "origin", fixture.workspace.branch, in: worktree)

        let status = try #require(await fixture.repo.manager.branchStatus(fixture.workspace))
        #expect(status.upstream == "origin/\(fixture.workspace.branch)")
        #expect(status.unpushedCommits == 0)
    }

    @Test func newerLocalCommitsAreCountedAsUnpushed() async throws {
        let (fixture, worktree) = try await committedBranch()
        defer { fixture.repo.remove() }
        try await fixture.repo.git("push", "-q", "origin", fixture.workspace.branch, in: worktree)
        try "y\n".write(to: worktree.appending(path: "y.txt"), atomically: true, encoding: .utf8)
        try await fixture.repo.git("add", "-A", in: worktree)
        try await fixture.repo.git("-c", "user.email=a@b", "-c", "user.name=u", "commit", "-qm", "y", in: worktree)

        let status = try #require(await fixture.repo.manager.branchStatus(fixture.workspace))
        #expect(status.commitsSinceBase == 2)
        #expect(status.unpushedCommits == 1)
    }

    @Test func neverPushed() async throws {
        let (fixture, _) = try await committedBranch()
        defer { fixture.repo.remove() }
        let status = try #require(await fixture.repo.manager.branchStatus(fixture.workspace))
        #expect(status.upstream == nil)
        #expect(status.unpushedCommits == 1)
    }
}

/// Stands in for the app's pipeline QA: returns prepared sessions in order, or throws.
final class FakePipelineQA: PipelineQA, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<QASessionResult, Error>]
    private(set) var calls = 0

    init(_ results: [Result<QASessionResult, Error>]) {
        self.results = results
    }

    func runQA(ticketID: String, repository: RepositoryConfig, onProgress: @escaping @Sendable (String) -> Void) async throws -> QASessionResult {
        let next: Result<QASessionResult, Error> = lock.withLock {
            calls += 1
            return results.count > 1 ? results.removeFirst() : results[0]
        }
        return try next.get()
    }

    /// A session with one bug per status given.
    static func session(_ statuses: [QAReplayResult.Status]) -> QASessionResult {
        let findings = statuses.indices.map { index in
            QAFinding(
                title: "Bug \(index + 1)", severity: .major, category: "functional", pageURL: "http://localhost:3000/x",
                steps: ["Open x"], expected: "It saves", actual: "It does not", evidence: "500 in log", reproduction: []
            )
        }
        return QASessionResult(
            directory: "/tmp/qa", report: QAReport(summary: "Tested x", coverage: [], findings: findings, notes: []),
            replays: statuses.map { QAReplayResult(status: $0, attempts: []) },
            startedAt: Date(), finishedAt: Date(), reportPath: "/tmp/qa/qa-report.md"
        )
    }
}

struct PipelineQATests {
    func verification(_ ticket: ImplementedTicket, _ runner: FakeAgentRunner, qa: FakePipelineQA) -> VerificationService {
        VerificationService(
            database: ticket.db, worktrees: ticket.fixture.repo.manager, runner: runner,
            implementation: ticket.fixture.service(runner), validationTimeout: .seconds(60), artifacts: ticket.fixture.artifacts,
            qa: qa
        )
    }

    func repository(_ ticket: ImplementedTicket, qa: Bool) -> RepositoryConfig {
        var config = ticket.repository(["true"])
        config.qa.runInPipeline = qa
        return config
    }

    @Test func qaRunsAfterPassingTestsAndReachesTheReviewer() async throws {
        let ticket = try await ImplementedTicket()
        defer { ticket.fixture.repo.remove() }
        let runner = FakeAgentRunner()
        let qa = FakePipelineQA([.success(FakePipelineQA.session([]))])

        _ = try await verification(ticket, runner, qa: qa).verify(
            ticketID: ticket.id, repository: repository(ticket, qa: true), tools: ticket.tools, maxFixAttempts: 1
        ) { _ in }

        #expect(qa.calls == 1)
        let runs = try await ticket.db.runs(ticketID: ticket.id)
        #expect(runs.map(\.kind).suffix(3) == [.validation, .qa, .review])
        #expect(runs.first { $0.kind == .qa }?.qa?.report.summary == "Tested x")
        #expect(runner.reviews.first?.qa?.report.summary == "Tested x")
        #expect(try await ticket.db.state(of: ticket.id) == .readyForHumanReview)
    }

    @Test func reproducedBugsGoToTheFixLoopThenEverythingRunsAgain() async throws {
        let ticket = try await ImplementedTicket()
        defer { ticket.fixture.repo.remove() }
        let runner = FakeAgentRunner()
        // First session: one reproduced and one unconfirmed bug; after the fix, none.
        let qa = FakePipelineQA([.success(FakePipelineQA.session([.confirmed, .notReproduced])), .success(FakePipelineQA.session([]))])

        _ = try await verification(ticket, runner, qa: qa).verify(
            ticketID: ticket.id, repository: repository(ticket, qa: true), tools: ticket.tools, maxFixAttempts: 1
        ) { _ in }

        #expect(qa.calls == 2)
        let fix = try #require(runner.implementations.first?.fixInstructions)
        #expect(fix.contains("Bug 1") && !fix.contains("Bug 2"), "only reproduced bugs are sent: \(fix)")
        let kinds = try await ticket.db.runs(ticketID: ticket.id).map(\.kind)
        #expect(kinds.suffix(6) == [.validation, .qa, .implementation, .validation, .qa, .review])
        #expect(try await ticket.db.state(of: ticket.id) == .readyForHumanReview)
    }

    @Test func bugsLeftAfterTheLastAttemptAreHandedOffNotHidden() async throws {
        let ticket = try await ImplementedTicket()
        defer { ticket.fixture.repo.remove() }
        let runner = FakeAgentRunner()
        let qa = FakePipelineQA([.success(FakePipelineQA.session([.confirmed]))])

        _ = try await verification(ticket, runner, qa: qa).verify(
            ticketID: ticket.id, repository: repository(ticket, qa: true), tools: ticket.tools, maxFixAttempts: 0
        ) { _ in }

        #expect(runner.implementations.isEmpty)
        #expect(runner.reviews.first?.qa?.confirmedCount == 1)
        #expect(try await ticket.db.state(of: ticket.id) == .readyForHumanReview)
    }

    @Test func qaThatCannotRunIsRecordedAndTheReviewStillHappens() async throws {
        let ticket = try await ImplementedTicket()
        defer { ticket.fixture.repo.remove() }
        let runner = FakeAgentRunner()
        let qa = FakePipelineQA([.failure(LocalRunError.notConfigured)])

        _ = try await verification(ticket, runner, qa: qa).verify(
            ticketID: ticket.id, repository: repository(ticket, qa: true), tools: ticket.tools, maxFixAttempts: 1
        ) { _ in }

        let qaRun = try #require(try await ticket.db.runs(ticketID: ticket.id).first { $0.kind == .qa })
        #expect(qaRun.outcome == .failed)
        #expect(runner.reviews.first?.qa == nil)
        #expect(try await ticket.db.state(of: ticket.id) == .readyForHumanReview)
    }

    @Test func noQAUnlessTheRepositoryAsks() async throws {
        let ticket = try await ImplementedTicket()
        defer { ticket.fixture.repo.remove() }
        let qa = FakePipelineQA([.success(FakePipelineQA.session([]))])

        _ = try await verification(ticket, FakeAgentRunner(), qa: qa).verify(
            ticketID: ticket.id, repository: repository(ticket, qa: false), tools: ticket.tools, maxFixAttempts: 1
        ) { _ in }

        #expect(qa.calls == 0)
        #expect(try await ticket.db.state(of: ticket.id) == .readyForHumanReview)
    }

    @Test func noQAWhileTestsFail() async throws {
        let ticket = try await ImplementedTicket()
        defer { ticket.fixture.repo.remove() }
        let qa = FakePipelineQA([.success(FakePipelineQA.session([]))])
        var config = ticket.repository(["exit 1"])
        config.qa.runInPipeline = true

        _ = try await verification(ticket, FakeAgentRunner(), qa: qa).verify(
            ticketID: ticket.id, repository: config, tools: ticket.tools, maxFixAttempts: 0
        ) { _ in }

        #expect(qa.calls == 0)
        #expect(try await ticket.db.state(of: ticket.id) == .readyForHumanReview)
    }
}

struct QAMemoryTests {
    @Test func storesTrimsAndForgetsNotesPerRepository() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "qa-memory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = QAMemoryStore(artifacts: ArtifactStore(root: root))
        #expect(store.read(repositoryID: "r1") == nil)

        try store.write("  # App\n- Save is in the header\n\n", repositoryID: "r1")
        #expect(store.read(repositoryID: "r1") == "# App\n- Save is in the header")
        #expect(store.read(repositoryID: "r2") == nil)

        try store.write(String(repeating: "x", count: QAMemoryStore.maxCharacters + 500), repositoryID: "r1")
        #expect(store.read(repositoryID: "r1")?.count == QAMemoryStore.maxCharacters)

        store.forget(repositoryID: "r1")
        #expect(store.read(repositoryID: "r1") == nil)
    }

    @Test func promptCarriesReplayVerdictsAndOldNotes() {
        let session = FakePipelineQA.session([.confirmed, .notReproduced])
        let prompt = QAMemoryPrompt.render(QAMemoryRequest(
            repositoryName: "omakase-v2", previous: "- Save is in the header", ticket: .sample(), session: session,
            workingDirectory: "/tmp", logURL: URL(filePath: "/tmp/memory.jsonl")
        ))
        #expect(prompt.contains("- Save is in the header"))
        #expect(prompt.contains("[REPRODUCED] Bug 1"))
        #expect(prompt.contains("[NOT REPRODUCED] Bug 2"))
    }

    @Test func qaPromptIncludesNotesOnlyWhenThereAreAny() throws {
        func request(memory: String?) -> QARequest {
            QARequest(
                ticket: .sample(), workspace: TicketWorkspace.sample(), plan: nil, changedFiles: [], appURL: "http://localhost:3000",
                signedIn: false, serviceLogs: [], logDirectory: "/tmp", excludedDirectory: "/tmp/x", mcpConfigPath: "/tmp/m.json",
                sessionDirectory: "/tmp", timeLimitMinutes: 10, memory: memory, logURL: URL(filePath: "/tmp/a.jsonl")
            )
        }
        #expect(QAPrompt.render(request(memory: "- Use the Leads tab")).contains("<qa_notes>\n- Use the Leads tab\n</qa_notes>"))
        #expect(!QAPrompt.render(request(memory: nil)).contains("qa_notes"))
    }
}
