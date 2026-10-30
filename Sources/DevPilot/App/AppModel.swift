import DevPilotCore
import Foundation
import Observation

/// UI state shared by the dashboard, ticket detail and menu bar.
@MainActor
@Observable
final class AppModel {
    private let orchestrator: WorkflowOrchestrator
    let databaseLocation: String

    private(set) var tickets: [Ticket] = []
    private(set) var states: [String: WorkflowState] = [:]
    private(set) var syncResults: [TicketProviderKind: ProviderSyncResult] = [:]
    private(set) var isSyncing = false
    var providerFilter: TicketProviderKind?
    var selectedTicketID: String?
    var lastError: String?

    private var started = false

    init(orchestrator: WorkflowOrchestrator, databaseLocation: String) {
        self.orchestrator = orchestrator
        self.databaseLocation = databaseLocation
    }

    var providerKinds: [TicketProviderKind] { orchestrator.providerKinds }

    var filteredTickets: [Ticket] {
        guard let providerFilter else { return tickets }
        return tickets.filter { $0.provider == providerFilter }
    }

    var selectedTicket: Ticket? {
        tickets.first { $0.id == selectedTicketID }
    }

    var runningCount: Int { states.values.filter(\.isAgentRunning).count }
    var pendingApprovalCount: Int { states.values.filter { $0 == .awaitingPlanApproval }.count }

    func state(of ticketID: String) -> WorkflowState {
        states[ticketID] ?? .discovered
    }

    /// Recovers interrupted runs, loads persisted tickets, then syncs. Safe to call more than once.
    func start() async {
        guard !started else { return }
        started = true
        do {
            let interrupted = try await orchestrator.recoverInterruptedRuns()
            if !interrupted.isEmpty {
                lastError = "\(interrupted.count) run(s) were interrupted when DevPilot last quit and have been marked failed."
            }
        } catch {
            lastError = "Crash recovery failed: \(error)"
        }
        await reload()
        await refresh()
    }

    func refresh() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        for result in await orchestrator.sync() {
            syncResults[result.kind] = result
        }
        await reload()
    }

    func select(_ ticketID: String) async {
        await perform { try await $0.select(ticketID: ticketID) }
    }

    func cancel(_ ticketID: String) async {
        await perform { try await $0.cancel(ticketID: ticketID) }
    }

    func events(for ticketID: String) async -> [WorkflowEvent] {
        do {
            return try await orchestrator.database.events(ticketID: ticketID)
        } catch {
            lastError = "Could not load history: \(error)"
            return []
        }
    }

    private func perform(_ action: (WorkflowOrchestrator) async throws -> Void) async {
        do {
            try await action(orchestrator)
        } catch {
            lastError = String(describing: error)
        }
        await reload()
    }

    private func reload() async {
        do {
            tickets = try await orchestrator.database.tickets()
            states = try await orchestrator.database.workflowStates()
        } catch {
            lastError = "Could not load tickets: \(error)"
        }
    }
}
