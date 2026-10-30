import Foundation
import GRDB
@testable import DevPilotCore

extension Investigation {
    static func sample(outcome: Outcome = .planReady, questions: [String] = [], summary: String = "Add retries.") -> Investigation {
        Investigation(
            outcome: outcome, summary: summary, requirements: ["Retry on 5xx"], assumptions: [],
            clarifyingQuestions: questions,
            impactedFiles: [ImpactedFile(path: "Sources/Webhooks.swift", reason: "delivery loop")],
            implementationSteps: ["Add backoff", "Add dead-letter table"],
            alternatives: [Alternative(approach: "Queue service", whyNotChosen: "new infrastructure")],
            tradeoffs: ["Slower failure detection"], risks: ["Duplicate deliveries"],
            testPlan: ["Unit test backoff schedule"], rollback: "Revert the commit.", openQuestions: []
        )
    }
}

/// Agent double driven by closures; records every request it receives.
final class FakeAgentRunner: AgentRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [InvestigationRequest] = []
    private var _implementations: [ImplementationRequest] = []
    private let behavior: @Sendable (InvestigationRequest) async throws -> Investigation
    private var _reviews: [ReviewRequest] = []
    private let implementation: @Sendable (ImplementationRequest) async throws -> ImplementationReport
    private let reviewing: @Sendable (ReviewRequest) async throws -> ReviewReport

    init(
        _ behavior: @escaping @Sendable (InvestigationRequest) async throws -> Investigation = { _ in .sample() },
        implement: @escaping @Sendable (ImplementationRequest) async throws -> ImplementationReport = { _ in .sample() },
        review: @escaping @Sendable (ReviewRequest) async throws -> ReviewReport = { _ in .sample() }
    ) {
        self.behavior = behavior
        self.implementation = implement
        self.reviewing = review
    }

    var requests: [InvestigationRequest] { lock.withLock { _requests } }
    var implementations: [ImplementationRequest] { lock.withLock { _implementations } }
    var reviews: [ReviewRequest] { lock.withLock { _reviews } }

    func review(_ request: ReviewRequest, onProgress: @escaping @Sendable (String) -> Void) async throws -> (ReviewReport, AgentRunStats) {
        lock.withLock { _reviews.append(request) }
        onProgress("Reading Sources/Webhooks.swift")
        return (try await reviewing(request), AgentRunStats(numTurns: 5, costUSD: 0.1))
    }

    func investigate(_ request: InvestigationRequest, onProgress: @escaping @Sendable (String) -> Void) async throws -> (Investigation, AgentRunStats) {
        lock.withLock { _requests.append(request) }
        onProgress("Reading README.md")
        return (try await behavior(request), AgentRunStats(numTurns: 3, costUSD: 0.01))
    }

    func implement(_ request: ImplementationRequest, onProgress: @escaping @Sendable (String) -> Void) async throws -> (ImplementationReport, AgentRunStats) {
        lock.withLock { _implementations.append(request) }
        onProgress("Editing Sources/Webhooks.swift")
        return (try await implementation(request), AgentRunStats(numTurns: 7, costUSD: 0.2))
    }
}

extension ImplementationReport {
    static func sample(outcome: Outcome = .completed) -> ImplementationReport {
        ImplementationReport(
            outcome: outcome, summary: "Added retries.", completedSteps: ["Add backoff"], deviations: [],
            commands: [CommandResult(command: "./mvnw test", succeeded: true, note: "42 tests")],
            remainingWork: [], notesForReviewer: ["Check jitter range"]
        )
    }
}

/// Writes an executable shell script standing in for the `claude` CLI. It records its
/// arguments, working directory and stdin next to itself, then runs `body`.
struct FakeClaude {
    let directory: URL
    let executable: URL

    init(body: String) throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "fake-claude-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        executable = directory.appending(path: "claude")
        let script = """
            #!/bin/sh
            printf '%s\\n' "$@" > '\(directory.path)/args.txt'
            pwd > '\(directory.path)/cwd.txt'
            env > '\(directory.path)/env.txt'
            cat > '\(directory.path)/stdin.txt'
            \(body)
            """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    func recorded(_ name: String) -> String {
        (try? String(contentsOf: directory.appending(path: name), encoding: .utf8)) ?? ""
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// stream-json lines for a successful run returning `investigation`.
    static func successStream(_ investigation: Investigation, worktree: String) throws -> String {
        let structured = String(decoding: try JSONEncoder().encode(investigation), as: UTF8.self)
        let lines = [
            #"{"type":"system","subtype":"init","model":"claude-test","tools":["Read","Grep","Glob"]}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"\#(worktree)/README.md"}}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Grep","input":{"pattern":"retry","path":"\#(worktree)/Sources"}}]}}"#,
            #"{"type":"result","subtype":"success","is_error":false,"num_turns":4,"total_cost_usd":0.12,"result":"done","structured_output":\#(structured)}"#,
        ]
        return lines.map { "echo '\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: "\n")
    }
}

extension Ticket {
    static func sample(_ externalID: String = "PLAT-182", description: String = "Retry webhooks.") -> Ticket {
        Ticket(
            provider: .jira, source: "acme.atlassian.net", externalID: externalID, title: "Webhook retries",
            description: description, status: "To Do", assignee: "Jane", url: URL(string: "https://acme.atlassian.net/browse/\(externalID)")!,
            comments: [TicketComment(author: "PM", body: "Cap at 10 minutes.", createdAt: Date(timeIntervalSince1970: 1_790_000_000))],
            acceptanceCriteria: ["Retries on 5xx"], fetchedAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
    }
}

extension TicketWorkspace {
    static func sample(ticketID: String = Ticket.sample().id, worktree: String = "/tmp/devpilot-worktree") -> TicketWorkspace {
        TicketWorkspace(
            ticketID: ticketID, repositoryID: "repo-1", repositoryName: "Payments", repositoryPath: "/tmp/payments",
            baseBranch: "main", baseCommit: "0123456789abcdef0123", branch: "devpilot/jira-plat-182",
            worktreePath: worktree, createdAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
    }
}

extension ReviewReport {
    static func sample(verdict: Verdict = .approve, findings: [Finding] = []) -> ReviewReport {
        ReviewReport(
            verdict: verdict, summary: "Looks right.", findings: findings,
            planCoverage: [PlanStep(step: "Add backoff", status: .done, note: "")],
            testAssessment: "Covered.", unresolvedRisks: []
        )
    }
}

extension AppDatabase {
    /// Rows for a ticket across all attempts, bypassing attempt scoping.
    func rowCountForTest(table: String, ticketID: String) async throws -> Int {
        try await writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE ticketID = ?", arguments: [ticketID]) ?? 0
        }
    }

    /// A clarification answer in the current attempt, so tests can check it is not carried over.
    func recordClarificationForTest(ticketID: String) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "INSERT INTO workflowEvent (ticketID, kind, message, createdAt, attempt) VALUES (?, 'clarification', 'old answer', 0, 1)",
                arguments: [ticketID]
            )
        }
    }
}
