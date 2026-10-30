import Foundation
import Testing
@testable import DevPilotCore

/// Runs the real Claude Code CLI. Opt-in because it uses your Claude login and quota:
///
///     DEVPILOT_LIVE_CLAUDE=1 swift test --filter LiveClaudeTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DEVPILOT_LIVE_CLAUDE"] == "1"))
struct LiveClaudeTests {
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
        let executable = try #require(ClaudeCLI.resolve(configuredPath: ""), "claude CLI not found")
        let service = InvestigationService(
            database: db,
            worktrees: repo.manager,
            runner: ClaudeCodeRunner(executable: executable, model: "haiku", timeout: .seconds(240)),
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
}
