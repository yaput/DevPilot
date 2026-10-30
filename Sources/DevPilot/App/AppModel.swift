import DevPilotCore
import Foundation
import Observation

/// UI state shared by the dashboard, ticket detail and menu bar.
@MainActor
@Observable
final class AppModel {
    private let settingsStore: SettingsStore
    private let factory: ProviderFactory
    private var orchestrator: WorkflowOrchestrator
    private var recoveredDatabasePath: String?

    private(set) var settings: ProviderSettings
    private(set) var databaseLocation: String
    private(set) var tickets: [Ticket] = []
    private(set) var states: [String: WorkflowState] = [:]
    private(set) var unassignedIDs: Set<String> = []
    private(set) var syncResults: [TicketProviderKind: ProviderSyncResult] = [:]
    private(set) var isSyncing = false
    var providerFilter: TicketProviderKind?
    var selectedTicketID: String?
    var lastError: String?

    private var started = false

    init(settingsStore: SettingsStore, factory: ProviderFactory) {
        self.settingsStore = settingsStore
        self.factory = factory
        let settings = settingsStore.load()
        self.settings = settings
        (orchestrator, databaseLocation, lastError) = Self.makeOrchestrator(settings: settings, factory: factory)
    }

    var providerKinds: [TicketProviderKind] { orchestrator.providerKinds }
    var hasProviders: Bool { !providerKinds.isEmpty }

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
        await recoverIfNeeded()
        await reload()
        await refresh()
    }

    /// Re-reads saved settings, rebuilds providers (switching database when sample data is
    /// toggled) and syncs.
    func reconfigure() async {
        settings = settingsStore.load()
        let message: String?
        (orchestrator, databaseLocation, message) = Self.makeOrchestrator(settings: settings, factory: factory)
        if let message { lastError = message }
        syncResults = [:]
        await recoverIfNeeded()
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

    /// Runs crash recovery once per database file per launch.
    private func recoverIfNeeded() async {
        guard recoveredDatabasePath != databaseLocation else { return }
        recoveredDatabasePath = databaseLocation
        do {
            let interrupted = try await orchestrator.recoverInterruptedRuns()
            if !interrupted.isEmpty {
                lastError = "\(interrupted.count) run(s) were interrupted when DevPilot last quit and have been marked failed."
            }
        } catch {
            lastError = "Crash recovery failed: \(error)"
        }
    }

    private func perform(_ action: (WorkflowOrchestrator) async throws -> Void) async {
        do {
            try await action(orchestrator)
        } catch {
            lastError = error.localizedDescription
        }
        await reload()
    }

    private func reload() async {
        do {
            tickets = try await orchestrator.database.tickets()
            states = try await orchestrator.database.workflowStates()
            unassignedIDs = try await orchestrator.database.unassignedTicketIDs()
        } catch {
            lastError = "Could not load tickets: \(error)"
        }
        if let selectedTicketID, !tickets.contains(where: { $0.id == selectedTicketID }) {
            self.selectedTicketID = nil
        }
    }

    /// Sample data and live data never share a database.
    private static func makeOrchestrator(
        settings: ProviderSettings,
        factory: ProviderFactory
    ) -> (WorkflowOrchestrator, String, String?) {
        let providers = factory.makeProviders(settings)
        let url = AppDatabase.defaultDirectory.appending(path: settings.useSampleData ? "devpilot-sample.sqlite" : "devpilot.sqlite")
        do {
            return (WorkflowOrchestrator(database: try AppDatabase.onDisk(at: url), providers: providers), url.path, nil)
        } catch {
            // An in-memory database only fails on a schema bug, which tests catch.
            let database = try! AppDatabase.inMemory()
            return (
                WorkflowOrchestrator(database: database, providers: providers),
                "In-memory (changes will not be saved)",
                "Could not open \(url.path): \(error.localizedDescription). Using a temporary in-memory database."
            )
        }
    }
}
