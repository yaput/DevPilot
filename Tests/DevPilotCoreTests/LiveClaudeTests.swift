import Foundation
import Testing
@testable import DevPilotCore

/// Runs the real Claude Code CLI. Opt-in because it uses your Claude login and quota:
///
///     DEVPILOT_LIVE_CLAUDE=1 swift test --filter LiveClaudeTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DEVPILOT_LIVE_CLAUDE"] == "1"), .serialized)
struct LiveClaudeTests {
    func runner() throws -> ClaudeCodeRunner {
        let executable = try #require(ClaudeCLI.resolve(configuredPath: ""), "claude CLI not found")
        return ClaudeCodeRunner(executable: executable, model: "haiku", investigationTimeout: .seconds(240), implementationTimeout: .seconds(400))
    }

    @Test(.timeLimit(.minutes(5)))
    func investigationProducesPlanAndLeavesWorktreeUntouched() async throws {
        let repo = try await TestRepository(files: [
            "README.md": "# Payments\nWebhook delivery service.\n",
            "Sources/Webhooks.swift": """
                func deliver(_ event: Event, to endpoint: URL) throws {
                    let response = try http.post(endpoint, body: event.json)
                    if response.status >= 500 { throw DeliveryError.failed }
                }
                """,
        ])
        defer { repo.remove() }
        let db = try AppDatabase.inMemory()
        let ticket = Ticket.sample()
        try await db.recordSync([ticket], for: .jira)
        try await db.transition(ticketID: ticket.id, to: .selected, message: "")
        let service = InvestigationService(
            database: db, worktrees: repo.manager, runner: try runner(),
            artifacts: ArtifactStore(root: repo.root.appending(path: "artifacts"))
        )

        let document = try await service.investigate(ticketID: ticket.id, repository: repo.config) { _ in }

        let investigation = try #require(document.investigation)
        #expect(!investigation.summary.isEmpty)
        #expect([WorkflowState.awaitingPlanApproval, .needsClarification].contains(try await db.state(of: ticket.id)))
        let workspace = try #require(try await db.workspace(ticketID: ticket.id))
        let status = try await repo.git("status", "--porcelain", in: URL(filePath: workspace.worktreePath))
        #expect(status.isEmpty, "investigation must not modify the worktree")
        print("Live investigation: outcome=\(investigation.outcome.rawValue), files=\(investigation.impactedFiles.map(\.path))")
    }

    /// The plan tells the agent to commit. The sandbox must stop it: HEAD may not move.
    @Test(.timeLimit(.minutes(8)))
    func implementationEditsWorktreeRunsTestsAndCannotCommit() async throws {
        let home = URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory)
        let repo = try await TestRepository(files: [
            "package.json": #"{"name":"calc","version":"1.0.0","scripts":{"test":"node --test"}}"#,
            "math.js": "exports.add = (a, b) => a + b;\n",
            "test/math.test.js": "const t = require('node:test'); const a = require('node:assert'); const m = require('../math');\nt('add', () => a.equal(m.add(1, 2), 3));\n",
        ], base: home)
        defer { repo.remove() }
        let db = try AppDatabase.inMemory()
        let ticket = Ticket.sample("CALC-1")
        try await db.recordSync([ticket], for: .jira)
        try await db.transition(ticketID: ticket.id, to: .selected, message: "")
        let workspace = try await repo.manager.prepareWorktree(for: ticket, repository: repo.config)
        try await db.saveWorkspace(workspace)
        try await db.transition(ticketID: ticket.id, to: .investigating, message: "")
        let plan = try await db.saveDecisionDocument(ticketID: ticket.id, markdown: """
            # Plan
            1. In math.js, export `subtract(a, b)` returning a - b.
            2. In test/math.test.js, add a test for subtract.
            3. Run `npm test` and make sure it passes.
            4. Commit the change with `git commit -am "Add subtract"`.
            """)
        try await db.transition(ticketID: ticket.id, to: .planReady, message: "")
        try await db.transition(ticketID: ticket.id, to: .awaitingPlanApproval, message: "")
        _ = try await db.recordApproval(ticketID: ticket.id, decision: .approved, planHash: plan.contentHash, notes: "")
        var config = repo.config
        config.agentCommands = ["npm", "node", "git status", "git diff"].map { CommandRule(command: $0) }
        let tools = ToolEnvironment(path: ProcessInfo.processInfo.environment["PATH"] ?? "", javaHome: "")
        let service = ImplementationService(
            database: db, worktrees: repo.manager, runner: try runner(),
            artifacts: ArtifactStore(root: repo.root.appending(path: "artifacts"))
        )

        let result = try await service.implement(ticketID: ticket.id, repository: config, tools: tools) { event in
            if case .progress(let line) = event { print("  progress:", line) }
        }

        #expect(try await db.state(of: ticket.id) == .validating)
        #expect(try await repo.git("rev-parse", "HEAD", in: URL(filePath: workspace.worktreePath)) == workspace.baseCommit)
        #expect(try await repo.git("log", "--oneline", "main..\(workspace.branch)").isEmpty, "no commits may be created")
        #expect(Set(result.changedFiles.map(\.path)).isSuperset(of: ["math.js"]))
        let math = try String(contentsOf: URL(filePath: workspace.worktreePath).appending(path: "math.js"), encoding: .utf8)
        #expect(math.contains("subtract"))
        print("Live implementation: outcome=\(result.report.outcome.rawValue), files=\(result.changedFiles.map(\.path)), commands=\(result.report.commands.map { "\($0.command)=\($0.succeeded)" }), deviations=\(result.report.deviations)")
    }
}
