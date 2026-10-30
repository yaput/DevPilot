import AppKit
import DevPilotCore
import Foundation
import Observation

/// Everything the ticket detail screen shows besides the ticket itself.
struct TicketDetailData: Equatable {
    var workspace: TicketWorkspace?
    var document: DecisionDocument?
    var runs: [AgentRun] = []
    var events: [WorkflowEvent] = []
}

/// Live progress of an investigation that is running in this app session.
struct RunActivity: Equatable {
    let startedAt: Date
    var lines: [String] = []

    mutating func append(_ line: String) {
        lines = Array((lines + [line]).suffix(12))
    }
}

/// UI state shared by the dashboard, ticket detail, settings and menu bar.
@MainActor
@Observable
final class AppModel {
    private let settingsStore: SettingsStore
    private let factory: ProviderFactory
    private var orchestrator: WorkflowOrchestrator
    private var investigations: InvestigationService
    private var recoveredDatabasePath: String?
    @ObservationIgnored private var runTasks: [String: Task<Void, Never>] = [:]

    let artifacts = ArtifactStore(root: AppDatabase.defaultDirectory.appending(path: "artifacts", directoryHint: .isDirectory))

    private(set) var settings: ProviderSettings
    private(set) var workspaceSettings: WorkspaceSettings
    private(set) var agentSettings: AgentSettings
    private(set) var databaseLocation: String
    private(set) var tickets: [Ticket] = []
    private(set) var states: [String: WorkflowState] = [:]
    private(set) var unassignedIDs: Set<String> = []
    private(set) var syncResults: [TicketProviderKind: ProviderSyncResult] = [:]
    private(set) var activity: [String: RunActivity] = [:]
    private(set) var isSyncing = false
    /// Bumped whenever ticket details change outside a state transition.
    private(set) var detailRevision = 0
    var providerFilter: TicketProviderKind?
    var selectedTicketID: String?
    var lastError: String?

    private var started = false

    init(settingsStore: SettingsStore, factory: ProviderFactory) {
        self.settingsStore = settingsStore
        self.factory = factory
        let settings = settingsStore.load(ProviderSettings.self)
        let workspaceSettings = settingsStore.load(WorkspaceSettings.self)
        let agentSettings = settingsStore.load(AgentSettings.self)
        self.settings = settings
        self.workspaceSettings = workspaceSettings
        self.agentSettings = agentSettings
        let (orchestrator, databaseLocation, message) = Self.makeOrchestrator(settings: settings, factory: factory)
        self.orchestrator = orchestrator
        self.databaseLocation = databaseLocation
        self.lastError = message
        investigations = Self.makeInvestigationService(
            database: orchestrator.database, workspace: workspaceSettings, agent: agentSettings, artifacts: artifacts
        )
        // Child processes are in their own process groups, so they would outlive the app.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            ProcessRunner.terminateAll()
        }
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

    // MARK: - Lifecycle and sync

    /// Recovers interrupted runs, loads persisted tickets, then syncs. Safe to call more than once.
    func start() async {
        guard !started else { return }
        started = true
        await recoverIfNeeded()
        await reload()
        await refresh()
    }

    /// Re-reads saved provider settings, rebuilds providers (switching database when sample data
    /// is toggled) and syncs.
    func reconfigure() async {
        settings = settingsStore.load(ProviderSettings.self)
        let message: String?
        (orchestrator, databaseLocation, message) = Self.makeOrchestrator(settings: settings, factory: factory)
        if let message { lastError = message }
        rebuildInvestigationService()
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

    // MARK: - Workflow actions

    func select(_ ticketID: String) async {
        await perform { try await $0.select(ticketID: ticketID) }
    }

    func cancel(_ ticketID: String) async {
        await perform { try await $0.cancel(ticketID: ticketID) }
    }

    func isRunning(_ ticketID: String) -> Bool {
        runTasks[ticketID] != nil
    }

    /// Runs a read-only investigation in the background. Progress appears in `activity`.
    func startInvestigation(_ ticketID: String, repositoryID: String) {
        guard runTasks[ticketID] == nil else { return }
        guard let repository = workspaceSettings.repository(id: repositoryID) else {
            lastError = "Choose a repository first. Repositories are set up in Settings → Repositories."
            return
        }
        let service = investigations
        let (events, continuation) = AsyncStream<InvestigationEvent>.makeStream()
        activity[ticketID] = RunActivity(startedAt: Date())
        runTasks[ticketID] = Task {
            let consumer = Task {
                for await event in events {
                    switch event {
                    case .started: await reload()
                    case .progress(let line):
                        // Copy, change, write back: reading and writing an @Observable property
                        // in one expression is an exclusivity violation that aborts the app.
                        if var run = activity[ticketID] {
                            run.append(line)
                            activity[ticketID] = run
                        }
                    }
                }
            }
            do {
                _ = try await service.investigate(ticketID: ticketID, repository: repository) { continuation.yield($0) }
            } catch is CancellationError {
                // Recorded as cancelled by the service.
            } catch {
                lastError = error.localizedDescription
            }
            continuation.finish()
            await consumer.value
            runTasks[ticketID] = nil
            activity[ticketID] = nil
            await reload()
            detailRevision += 1
        }
    }

    func stopInvestigation(_ ticketID: String) {
        runTasks[ticketID]?.cancel()
    }

    func answerClarification(_ ticketID: String, answers: String, repositoryID: String) async {
        do {
            try await orchestrator.database.recordClarification(ticketID: ticketID, answers: answers)
        } catch {
            lastError = error.localizedDescription
            return
        }
        startInvestigation(ticketID, repositoryID: repositoryID)
    }

    func decide(_ ticketID: String, decision: ApprovalDecision, planHash: String, notes: String) async {
        do {
            _ = try await orchestrator.database.recordApproval(ticketID: ticketID, decision: decision, planHash: planHash, notes: notes)
        } catch {
            lastError = error.localizedDescription
        }
        await reload()
        detailRevision += 1
    }

    func loadDetail(_ ticketID: String) async -> TicketDetailData {
        let database = orchestrator.database
        do {
            return TicketDetailData(
                workspace: try await database.workspace(ticketID: ticketID),
                document: try await database.latestDecisionDocument(ticketID: ticketID),
                runs: try await database.runs(ticketID: ticketID),
                events: try await database.events(ticketID: ticketID)
            )
        } catch {
            lastError = "Could not load ticket details: \(error.localizedDescription)"
            return TicketDetailData()
        }
    }

    // MARK: - Settings

    func applyWorkspaceSettings(_ settings: WorkspaceSettings) {
        guard settings != workspaceSettings else { return }
        persist(settings)
        workspaceSettings = settings
        rebuildInvestigationService()
    }

    func applyAgentSettings(_ settings: AgentSettings) {
        guard settings != agentSettings else { return }
        persist(settings)
        agentSettings = settings
        rebuildInvestigationService()
    }

    var resolvedClaudeExecutable: URL? {
        ClaudeCLI.resolve(configuredPath: agentSettings.claudePath)
    }

    // MARK: - Internals

    private func persist<T: StoredSettings>(_ settings: T) {
        do {
            try settingsStore.save(settings)
        } catch {
            lastError = "Could not save settings: \(error.localizedDescription)"
        }
    }

    /// Runs already in progress keep the service they started with.
    private func rebuildInvestigationService() {
        investigations = Self.makeInvestigationService(
            database: orchestrator.database, workspace: workspaceSettings, agent: agentSettings, artifacts: artifacts
        )
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

    private static func makeInvestigationService(
        database: AppDatabase,
        workspace: WorkspaceSettings,
        agent: AgentSettings,
        artifacts: ArtifactStore
    ) -> InvestigationService {
        let runner: any AgentRunner = if let executable = ClaudeCLI.resolve(configuredPath: agent.claudePath) {
            ClaudeCodeRunner(executable: executable, model: agent.model, timeout: .seconds(max(1, agent.investigationTimeoutMinutes) * 60))
        } else {
            UnavailableAgentRunner(reason: "Claude Code was not found. Set its location in Settings → Agent.")
        }
        return InvestigationService(
            database: database,
            worktrees: GitWorktreeManager(worktreeRoot: workspace.resolvedWorktreeRoot),
            runner: runner,
            artifacts: artifacts
        )
    }
}
