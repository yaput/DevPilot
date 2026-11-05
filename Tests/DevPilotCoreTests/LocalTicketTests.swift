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

struct LocalTicketDeletionTests {
    @Test func deletesTheTicketAndEverythingRecordedAboutIt() async throws {
        let fixture = try await ApprovedTicket()
        defer { fixture.repo.remove() }
        let local = try await fixture.db.addLocalTicket(title: "Try", description: "", acceptanceCriteria: [], type: .bug, repositoryID: "r")
        try await fixture.db.transition(ticketID: local.id, to: .selected, message: "")

        try await fixture.db.deleteLocalTicket(id: local.id)

        #expect(try await fixture.db.ticket(id: local.id) == nil)
        #expect(try await fixture.db.state(of: local.id) == nil)
        #expect(!(try await fixture.db.tickets()).contains { $0.id == local.id })
        // Other tickets are untouched.
        #expect(try await fixture.db.latestDecisionDocument(ticketID: fixture.ticket.id) != nil)
    }

    @Test func aTicketWithPlansRunsAndAWorkspaceIsDeletedCompletely() async throws {
        let db = try AppDatabase.inMemory()
        let local = try await db.addLocalTicket(title: "Try", description: "", acceptanceCriteria: [], type: .bug, repositoryID: "r")
        try await db.transition(ticketID: local.id, to: .selected, message: "")
        try await db.saveWorkspace(TicketWorkspace.sample(ticketID: local.id))
        // Must not trip a foreign key: every table that points at the ticket is cleared first.
        try await db.deleteLocalTicket(id: local.id)
        #expect(try await db.workspace(ticketID: local.id) == nil)
    }

    @Test func syncedTicketsCannotBeDeleted() async throws {
        let db = try AppDatabase.inMemory()
        try await db.recordSync([.sample()], for: .jira)
        await #expect(throws: TicketDeletionError.notLocal) { try await db.deleteLocalTicket(id: Ticket.sample().id) }
    }

    @Test func numbersAreNeverReused() async throws {
        let db = try AppDatabase.inMemory()
        let first = try await db.addLocalTicket(title: "1", description: "", acceptanceCriteria: [], type: .bug, repositoryID: "r")
        let second = try await db.addLocalTicket(title: "2", description: "", acceptanceCriteria: [], type: .bug, repositoryID: "r")
        try await db.deleteLocalTicket(id: second.id)
        try await db.deleteLocalTicket(id: first.id)
        // DP-1's worktree folder and branch may still exist, so the next ticket is DP-3.
        let next = try await db.addLocalTicket(title: "3", description: "", acceptanceCriteria: [], type: .bug, repositoryID: "r")
        #expect(next.externalID == "DP-3")
    }
}

struct UnfollowTests {
    @Test func anUnfollowedTicketStaysHiddenThroughSyncsAndComesBackAsItWas() async throws {
        let db = try AppDatabase.inMemory()
        let ticket = Ticket.sample("PLAT-1")
        try await db.recordSync([ticket, .sample("PLAT-2")], for: .jira)
        try await db.transition(ticketID: ticket.id, to: .selected, message: "")

        try await db.setFollowing(false, ticketID: ticket.id)
        #expect(!(try await db.tickets()).contains { $0.id == ticket.id })
        #expect(try await db.unfollowedTickets().map(\.id) == [ticket.id])

        // Still assigned in Jira: the sync updates it but does not bring it back.
        try await db.recordSync([ticket, .sample("PLAT-2")], for: .jira)
        #expect(!(try await db.tickets()).contains { $0.id == ticket.id })

        try await db.setFollowing(true, ticketID: ticket.id)
        #expect((try await db.tickets()).contains { $0.id == ticket.id })
        #expect(try await db.state(of: ticket.id) == .selected)
        #expect(try await db.unfollowedTickets().isEmpty)
    }

    @Test func autopilotNeverPicksAnUnfollowedTicket() async throws {
        let db = try AppDatabase.inMemory()
        let ticket = Ticket.sample("PLAT-1")
        try await db.recordSync([ticket], for: .jira)
        #expect(try await db.untouchedTickets()[ticket.id] != nil)
        try await db.setFollowing(false, ticketID: ticket.id)
        #expect(try await db.untouchedTickets()[ticket.id] == nil)
    }

    @Test func devPilotTicketsAreDeletedNotUnfollowed() async throws {
        let db = try AppDatabase.inMemory()
        let local = try await db.addLocalTicket(title: "t", description: "", acceptanceCriteria: [], type: .bug, repositoryID: "r")
        await #expect(throws: TicketDeletionError.local) { try await db.setFollowing(false, ticketID: local.id) }
    }

    @Test func notWhileARunIsInProgress() async throws {
        let fixture = try await ApprovedTicket()
        defer { fixture.repo.remove() }
        _ = try await fixture.db.beginImplementation(ticketID: fixture.ticket.id, logPath: "/tmp/x")
        await #expect(throws: TicketDeletionError.running) { try await fixture.db.setFollowing(false, ticketID: fixture.ticket.id) }
    }
}
