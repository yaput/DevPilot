import Foundation
import Testing
@testable import DevPilotCore

struct LocalTicketTests {
    @Test func numberedPerDatabaseAndUntouchedBySyncs() async throws {
        let db = try AppDatabase.inMemory()
        let first = try await db.addLocalTicket(title: "Try QA", description: "d", acceptanceCriteria: ["a", "b"], type: .bug, repositoryID: "repo-1")
        let second = try await db.addLocalTicket(title: "Another", description: "", acceptanceCriteria: [], type: .feature, repositoryID: "repo-2")
        #expect(first.externalID == "DP-1" && second.externalID == "DP-2")
        #expect(first.id == "local:repo-1/DP-1")

        // Syncs only ever touch their own provider's tickets.
        try await db.recordSync([.sample()], for: .jira)
        try await db.recordSync([], for: .jira)
        let tickets = try await db.tickets()
        #expect(tickets.contains { $0.id == first.id && $0.acceptanceCriteria == ["a", "b"] && $0.type == .bug })
        #expect(try await db.unassignedTicketIDs().contains(first.id) == false)
        #expect(try await db.state(of: first.id) == .discovered)
    }

    @Test func routesToItsRepositoryAndNamesBranchesByType() {
        var settings = WorkspaceSettings()
        let omakase = RepositoryConfig(id: "repo-2", name: "omakase-v2", path: "/r2", baseBranch: "main")
        settings.repositories = [RepositoryConfig(id: "repo-1", name: "talkroom", path: "/r1", baseBranch: "develop"), omakase]
        let ticket = Ticket(
            provider: .local, source: "repo-2", externalID: "DP-3", title: "t", description: "", status: "Open", assignee: nil,
            url: URL(string: "devpilot://ticket/DP-3")!, comments: [], acceptanceCriteria: [], fetchedAt: Date(), type: .bug
        )
        #expect(settings.suggestedRepository(for: ticket)?.id == "repo-2")
        #expect(GitWorktreeManager.branchName(for: ticket) == "fix/DP-3")
    }
}
