import Foundation
import Testing
@testable import DevPilotCore

struct PersistenceTests {
    let db: AppDatabase
    let ticket: Ticket

    init() async throws {
        db = try AppDatabase.inMemory()
        // Whole-second timestamp: dates are stored as seconds since 1970, which drops sub-microsecond precision.
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        ticket = try await MockTicketProvider.sample(.jira, now: now).assignedTickets()[0]
        try await db.recordSync([ticket], for: .jira)
    }

    /// Drives the ticket to `awaiting_plan_approval` with the given plan.
    func preparePlan(_ markdown: String) async throws -> DecisionDocument {
        try await db.transition(ticketID: ticket.id, to: .selected, message: "")
        try await db.transition(ticketID: ticket.id, to: .investigating, message: "")
        let document = try await db.saveDecisionDocument(ticketID: ticket.id, markdown: markdown)
        try await db.transition(ticketID: ticket.id, to: .planReady, message: "")
        try await db.transition(ticketID: ticket.id, to: .awaitingPlanApproval, message: "")
        return document
    }

    @Test func newTicketStartsDiscoveredWithAuditEvent() async throws {
        #expect(try await db.state(of: ticket.id) == .discovered)
        let events = try await db.events(ticketID: ticket.id)
        #expect(events.count == 1)
        #expect(events[0].fromState == nil && events[0].toState == .discovered)
    }

    @Test func ticketRoundTripsExactly() async throws {
        #expect(try await db.tickets() == [ticket])
    }

    @Test func resyncUpdatesContentButKeepsState() async throws {
        try await db.transition(ticketID: ticket.id, to: .selected, message: "")
        let updated = Ticket(
            provider: ticket.provider, source: ticket.source, externalID: ticket.externalID, title: "Renamed", description: ticket.description,
            status: "In Progress", assignee: ticket.assignee, url: ticket.url, comments: [],
            acceptanceCriteria: ticket.acceptanceCriteria, fetchedAt: Date()
        )
        try await db.recordSync([updated], for: .jira)
        #expect(try await db.tickets().first?.title == "Renamed")
        #expect(try await db.state(of: ticket.id) == .selected)
        #expect(try await db.events(ticketID: ticket.id).count == 2)
    }

    @Test func illegalTransitionIsRejectedAndLeavesNoTrace() async throws {
        await #expect(throws: WorkflowError.illegalTransition(from: .discovered, to: .implementing)) {
            try await db.transition(ticketID: ticket.id, to: .implementing, message: "")
        }
        #expect(try await db.state(of: ticket.id) == .discovered)
        #expect(try await db.events(ticketID: ticket.id).count == 1)
    }

    @Test func unknownTicketIsRejected() async throws {
        await #expect(throws: WorkflowError.unknownTicket("jira:sample/NOPE-1")) {
            try await db.transition(ticketID: "jira:sample/NOPE-1", to: .selected, message: "")
        }
    }

    @Test func approvalUnlocksImplementationGate() async throws {
        let plan = try await preparePlan("# Plan v1")
        #expect(try await db.implementationGate(ticketID: ticket.id) == .blocked(.wrongState(.awaitingPlanApproval)))

        _ = try await db.recordApproval(ticketID: ticket.id, decision: .approved, planHash: plan.contentHash, notes: "LGTM")

        #expect(try await db.state(of: ticket.id) == .approved)
        #expect(try await db.implementationGate(ticketID: ticket.id) == .allowed)
        let last = try await db.events(ticketID: ticket.id).last
        #expect(last?.kind == .approval)
        #expect(last?.message.contains("LGTM") == true)
    }

    @Test func approvingStaleHashFailsAtomically() async throws {
        _ = try await preparePlan("# Plan v1")
        await #expect(throws: WorkflowError.planHashMismatch) {
            _ = try await db.recordApproval(ticketID: ticket.id, decision: .approved, planHash: DecisionDocument.hash("other"), notes: "")
        }
        #expect(try await db.state(of: ticket.id) == .awaitingPlanApproval)
        #expect(try await db.latestApproval(ticketID: ticket.id) == nil)
    }

    @Test func revisionRequiresApprovingTheNewPlan() async throws {
        let v1 = try await preparePlan("# Plan v1")
        _ = try await db.recordApproval(ticketID: ticket.id, decision: .revisionRequested, planHash: v1.contentHash, notes: "Add tests")
        #expect(try await db.state(of: ticket.id) == .needsRevision)

        try await db.transition(ticketID: ticket.id, to: .investigating, message: "")
        let v2 = try await db.saveDecisionDocument(ticketID: ticket.id, markdown: "# Plan v2")
        #expect(v2.version == 2)
        try await db.transition(ticketID: ticket.id, to: .planReady, message: "")
        try await db.transition(ticketID: ticket.id, to: .awaitingPlanApproval, message: "")

        await #expect(throws: WorkflowError.planHashMismatch) {
            _ = try await db.recordApproval(ticketID: ticket.id, decision: .approved, planHash: v1.contentHash, notes: "")
        }
        _ = try await db.recordApproval(ticketID: ticket.id, decision: .approved, planHash: v2.contentHash, notes: "")
        #expect(try await db.implementationGate(ticketID: ticket.id) == .allowed)
    }

    @Test func planCannotBeReplacedAfterApproval() async throws {
        let plan = try await preparePlan("# Plan v1")
        _ = try await db.recordApproval(ticketID: ticket.id, decision: .approved, planHash: plan.contentHash, notes: "")
        await #expect(throws: WorkflowError.decisionDocumentNotAllowed(in: .approved)) {
            _ = try await db.saveDecisionDocument(ticketID: ticket.id, markdown: "# Sneaky v2")
        }
    }

    @Test func approvalOutsideAwaitingStateIsRejected() async throws {
        await #expect(throws: WorkflowError.illegalTransition(from: .discovered, to: .approved)) {
            _ = try await db.recordApproval(ticketID: ticket.id, decision: .approved, planHash: "x", notes: "")
        }
    }

    @Test func interruptedRunsAreFailedNotResumed() async throws {
        let others = try await MockTicketProvider.sample(.shortcut).assignedTickets()
        try await db.recordSync(others, for: .shortcut)
        try await db.transition(ticketID: ticket.id, to: .selected, message: "")
        try await db.transition(ticketID: ticket.id, to: .investigating, message: "")

        let recovered = try await db.failInterruptedRuns(message: "Interrupted")

        #expect(recovered == [ticket.id])
        #expect(try await db.state(of: ticket.id) == .failed)
        #expect(try await db.state(of: others[0].id) == .discovered)
        #expect(try await db.implementationGate(ticketID: ticket.id) == .blocked(.wrongState(.failed)))
    }

    @Test func ticketsNoLongerReturnedAreHidden() async throws {
        let all = try await MockTicketProvider.sample(.jira).assignedTickets()
        try await db.recordSync(all, for: .jira)
        #expect(try await db.tickets().count == 3)

        try await db.recordSync([all[1]], for: .jira)

        #expect(try await db.tickets().map(\.id) == [all[1].id])
        #expect(try await db.unassignedTicketIDs() == [all[0].id, all[2].id])
    }

    @Test func unassignedTicketsStayVisibleWhileInProgress() async throws {
        try await db.transition(ticketID: ticket.id, to: .selected, message: "")
        try await db.recordSync([], for: .jira)

        #expect(try await db.tickets().map(\.id) == [ticket.id])
        #expect(try await db.unassignedTicketIDs() == [ticket.id])

        try await db.transition(ticketID: ticket.id, to: .cancelled, message: "")
        #expect(try await db.tickets().isEmpty)
    }

    @Test func syncOnlyAffectsItsOwnProvider() async throws {
        try await db.recordSync([], for: .shortcut)
        #expect(try await db.tickets().map(\.id) == [ticket.id])
    }

    @Test func reassignedTicketReappears() async throws {
        try await db.recordSync([], for: .jira)
        try await db.recordSync([ticket], for: .jira)
        #expect(try await db.unassignedTicketIDs().isEmpty)
        #expect(try await db.tickets().map(\.id) == [ticket.id])
    }

    @Test func sameKeyOnDifferentSitesIsTwoTickets() async throws {
        let otherSite = Ticket(
            provider: .jira, source: "other.atlassian.net", externalID: ticket.externalID, title: "Unrelated",
            description: "", status: "To Do", assignee: nil, url: ticket.url, comments: [],
            acceptanceCriteria: [], fetchedAt: ticket.fetchedAt
        )
        try await db.transition(ticketID: ticket.id, to: .selected, message: "")
        try await db.recordSync([otherSite], for: .jira)

        #expect(try await db.state(of: otherSite.id) == .discovered)
        #expect(try await db.state(of: ticket.id) == .selected)
        #expect(Set(try await db.tickets().map(\.id)) == [ticket.id, otherSite.id])
    }

    @Test func dataSurvivesReopeningOnDisk() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "devpilot-test-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "test.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        do {
            let first = try AppDatabase.onDisk(at: url)
            try await first.recordSync([ticket], for: .jira)
            try await first.transition(ticketID: ticket.id, to: .selected, message: "")
        }
        let reopened = try AppDatabase.onDisk(at: url)
        let tickets = try await reopened.tickets()
        let state = try await reopened.state(of: ticket.id)
        #expect(tickets == [ticket])
        #expect(state == .selected)
    }
}
