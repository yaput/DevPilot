import Foundation
import Testing
@testable import DevPilotCore

struct AutopilotTests {
    @Test func onlyUntouchedDiscoveredTicketsAreCandidates() async throws {
        let db = try AppDatabase.inMemory()
        let fresh = Ticket.sample("PLAT-1")
        let selected = Ticket.sample("PLAT-2")
        let cancelledAndBack = Ticket.sample("PLAT-3")
        try await db.recordSync([fresh, selected, cancelledAndBack], for: .jira)
        try await db.transition(ticketID: selected.id, to: .selected, message: "Selected by user")
        // Cancelled, then restarted by the user: no longer untouched even if it were back in discovered.
        try await db.transition(ticketID: cancelledAndBack.id, to: .cancelled, message: "")

        let untouched = try await db.untouchedTickets()
        #expect(Set(untouched.keys) == [fresh.id])
        #expect(abs(untouched[fresh.id]!.timeIntervalSinceNow) < 60)
    }

    @Test func aResyncDoesNotMakeATicketNewAgain() async throws {
        let db = try AppDatabase.inMemory()
        let ticket = Ticket.sample("PLAT-1")
        try await db.recordSync([ticket], for: .jira)
        let first = try #require(try await db.untouchedTickets()[ticket.id])
        try await Task.sleep(for: .milliseconds(20))
        try await db.recordSync([ticket], for: .jira)
        #expect(try await db.untouchedTickets()[ticket.id] == first)
    }

    @Test func investigatesOnlyTicketsDiscoveredAfterItWasTurnedOn() {
        var config = AutopilotConfig()
        let now = Date()
        #expect(!config.shouldInvestigate(discoveredAt: now))

        config.investigateNewSince = now
        #expect(config.shouldInvestigate(discoveredAt: now.addingTimeInterval(10)))
        #expect(!config.shouldInvestigate(discoveredAt: now.addingTimeInterval(-10)))
    }

    @Test func repositoriesSavedBeforeAutopilotDecodeWithItOff() throws {
        let old = #"{"id": "r1", "name": "api", "path": "/tmp/api", "baseBranch": "main"}"#
        let repository = try JSONDecoder().decode(RepositoryConfig.self, from: Data(old.utf8))
        #expect(!repository.autopilot.investigatesNewTickets)
        #expect(!repository.autopilot.implementWhenApproved)

        var on = repository
        on.autopilot.investigateNewSince = Date(timeIntervalSince1970: 1_000)
        on.autopilot.implementWhenApproved = true
        let roundTrip = try JSONDecoder().decode(RepositoryConfig.self, from: JSONEncoder().encode(on))
        #expect(roundTrip.autopilot == on.autopilot)
    }
}
