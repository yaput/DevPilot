import Foundation
import Testing
@testable import DevPilotCore

private struct FailingProvider: TicketProvider {
    let kind: TicketProviderKind
    func assignedTickets() async throws -> [Ticket] { throw TicketProviderError.unauthorized }
    func ticket(id: String) async throws -> Ticket { throw TicketProviderError.unauthorized }
    func checkConnection() async throws -> String { throw TicketProviderError.unauthorized }
}

struct WorkflowOrchestratorTests {
    @Test func syncsBothProvidersWithDistinctIdentity() async throws {
        let db = try AppDatabase.inMemory()
        let orchestrator = WorkflowOrchestrator(database: db, providers: [MockTicketProvider.sample(.shortcut), MockTicketProvider.sample(.jira)])

        let results = await orchestrator.sync()

        #expect(results.map(\.outcome) == [.synced(ticketCount: 3), .synced(ticketCount: 3)])
        let tickets = try await db.tickets()
        #expect(tickets.count == 6)
        #expect(Set(tickets.map(\.provider)) == [.shortcut, .jira])
        #expect(tickets.allSatisfy { $0.id == "\($0.provider.rawValue):sample/\($0.externalID)" })
    }

    @Test func oneProviderFailingDoesNotBlockTheOther() async throws {
        let db = try AppDatabase.inMemory()
        let orchestrator = WorkflowOrchestrator(database: db, providers: [FailingProvider(kind: .shortcut), MockTicketProvider.sample(.jira)])

        let results = await orchestrator.sync()

        #expect(results[0].kind == .jira && results[0].outcome == .synced(ticketCount: 3))
        guard case .failed = results[1].outcome else {
            Issue.record("Expected shortcut sync to fail")
            return
        }
        #expect(try await db.tickets().count == 3)
    }

    @Test func syncCanBeLimitedToSelectedProviders() async throws {
        let db = try AppDatabase.inMemory()
        let orchestrator = WorkflowOrchestrator(database: db, providers: [MockTicketProvider.sample(.shortcut), MockTicketProvider.sample(.jira)])

        let results = await orchestrator.sync([.jira])

        #expect(results.map(\.kind) == [.jira])
        #expect(try await db.tickets().allSatisfy { $0.provider == .jira })
    }

    @Test func providerReturningForeignTicketsIsRejected() async throws {
        let db = try AppDatabase.inMemory()
        let jiraTickets = try await MockTicketProvider.sample(.jira).assignedTickets()
        let mislabeled = MockTicketProvider(kind: .shortcut, tickets: jiraTickets)
        let orchestrator = WorkflowOrchestrator(database: db, providers: [mislabeled])

        let results = await orchestrator.sync()

        guard case .failed = results[0].outcome else {
            Issue.record("Expected sync to fail")
            return
        }
        #expect(try await db.tickets().isEmpty)
    }

    @Test func userActionsFollowStateMachine() async throws {
        let db = try AppDatabase.inMemory()
        let orchestrator = WorkflowOrchestrator(database: db, providers: [MockTicketProvider.sample(.jira)])
        _ = await orchestrator.sync()
        let id = try await db.tickets()[0].id

        try await orchestrator.select(ticketID: id)
        #expect(try await db.state(of: id) == .selected)
        try await orchestrator.cancel(ticketID: id)
        #expect(try await db.state(of: id) == .cancelled)
        await #expect(throws: WorkflowError.illegalTransition(from: .cancelled, to: .cancelled)) {
            try await orchestrator.cancel(ticketID: id)
        }
    }
}
