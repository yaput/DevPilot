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

    var latestImplementation: AgentRun? {
        runs.last { $0.kind == .implementation }
    }
}

/// Live progress of an agent run in this app session.
struct RunActivity: Equatable {
    let kind: AgentRun.Kind
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
    private struct Services {
        let investigation: InvestigationService
        let implementation: ImplementationService
    }

    private let settingsStore: SettingsStore
    private let factory: ProviderFactory
    private var orchestrator: WorkflowOrchestrator
    private var services: Services
    private var recoveredDatabasePath: String?
    @ObservationIgnored private var runTasks: [String: Task<Void, Never>] = [:]

    let artifacts = ArtifactStore(root: AppDatabase.defaultDirectory.appending(path: "artifacts", directoryHint: .isDirectory))
    /// Editors installed on this Mac, detected once per launch.
    let editors = EditorApp.installed()

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
        let agentSettings = settingsStore.load(AgentSettings.self)
        var workspaceSettings = settingsStore.load(WorkspaceSettings.self)
        // Repositories added before per-repository commands existed get the detected presets.
        if Self.fillMissingCommandPresets(&workspaceSettings) {
            try? settingsStore.save(workspaceSettings)
        }
        self.settings = settings
        self.workspaceSettings = workspaceSettings
        self.agentSettings = agentSettings
        let (orchestrator, databaseLocation, message) = Self.makeOrchestrator(settings: settings, factory: factory)
        self.orchestrator = orchestrator
        self.databaseLocation = databaseLocation
        self.lastError = message
        services = Self.makeServices(
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
    /// Settings that affect agent runs are locked while any run is in progress.
    var hasActiveRuns: Bool { !activity.isEmpty }

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
        guard !hasActiveRuns else {
            lastError = "Settings were saved, but they take effect after the running agent finishes."
            return
        }
        settings = settingsStore.load(ProviderSettings.self)
        let message: String?
        (orchestrator, databaseLocation, message) = Self.makeOrchestrator(settings: settings, factory: factory)
        if let message { lastError = message }
        rebuildServices()
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
    /// `baseBranch` overrides the repository's base when the ticket has no worktree yet.
    func startInvestigation(_ ticketID: String, repositoryID: String, baseBranch: String? = nil) {
        guard let repository = workspaceSettings.repository(id: repositoryID) else {
            lastError = "Choose a repository first. Repositories are set up in Settings → Repositories."
            return
        }
        let service = services.investigation
        launch(.investigation, ticketID: ticketID) { onEvent in
            let override = baseBranch?.trimmingCharacters(in: .whitespaces)
            _ = try await service.investigate(
                ticketID: ticketID, repository: repository,
                baseBranch: override?.isEmpty == false ? override : nil, onEvent: onEvent
            )
        }
    }

    /// Implements the approved plan in the background, with the repository's setup and agent commands.
    func startImplementation(_ ticketID: String, repositoryID: String) {
        guard let repository = workspaceSettings.repository(id: repositoryID) else {
            lastError = "This ticket's repository is no longer in Settings → Repositories. Add it again to implement."
            return
        }
        let service = services.implementation
        launch(.implementation, ticketID: ticketID) { [self] onEvent in
            var tools = agentSettings.toolEnvironment
            if tools.path.isEmpty {
                onEvent(.progress("Importing PATH and JAVA_HOME from your login shell"))
                tools = try await ToolEnvironment.importFromLoginShell()
                var updated = agentSettings
                updated.toolPath = tools.path
                updated.javaHome = tools.javaHome
                persist(updated)
                agentSettings = updated
            }
            _ = try await service.implement(ticketID: ticketID, repository: repository, tools: tools, onEvent: onEvent)
        }
    }

    /// After a failed or stopped implementation: back to the approved plan, then implement again.
    func retryImplementation(_ ticketID: String, repositoryID: String) async {
        do {
            try await orchestrator.database.returnToApprovedPlan(ticketID: ticketID)
        } catch {
            lastError = error.localizedDescription
            await reload()
            return
        }
        await reload()
        startImplementation(ticketID, repositoryID: repositoryID)
    }

    func stopRun(_ ticketID: String) {
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

    /// Removes the ticket's worktree (refused if it has uncommitted changes) so the next
    /// investigation starts fresh from the repository's current base branch.
    func discardWorktree(_ ticketID: String) async {
        guard !isRunning(ticketID) else { return }
        do {
            guard let workspace = try await orchestrator.database.workspace(ticketID: ticketID) else { return }
            let branchDeleted = try await GitWorktreeManager(worktreeRoot: workspaceSettings.resolvedWorktreeRoot)
                .removeWorktree(workspace)
            try await orchestrator.database.deleteWorkspace(ticketID: ticketID)
            if !branchDeleted {
                lastError = "The worktree was removed. Branch \(workspace.branch) has commits, so it was kept."
            }
        } catch {
            lastError = "Could not discard the worktree: \(error.localizedDescription)"
        }
        await reload()
        detailRevision += 1
    }

    /// The ticket's worktree and everything in it that differs from its base commit.
    func loadChanges(_ ticketID: String) async throws -> (TicketWorkspace, [FileDiff]) {
        guard let workspace = try await orchestrator.database.workspace(ticketID: ticketID) else {
            throw ImplementationError.worktreeMissing("this ticket has no worktree yet")
        }
        guard FileManager.default.fileExists(atPath: workspace.worktreePath) else {
            throw ImplementationError.worktreeMissing(workspace.worktreePath)
        }
        let files = try await GitWorktreeManager(worktreeRoot: workspaceSettings.resolvedWorktreeRoot)
            .diff(in: workspace.worktreePath, against: workspace.baseCommit)
        return (workspace, files)
    }

    // MARK: - Settings

    func applyWorkspaceSettings(_ settings: WorkspaceSettings) {
        guard settings != workspaceSettings, !hasActiveRuns else { return }
        persist(settings)
        workspaceSettings = settings
        rebuildServices()
    }

    func applyAgentSettings(_ settings: AgentSettings) {
        guard settings != agentSettings, !hasActiveRuns else { return }
        persist(settings)
        agentSettings = settings
        rebuildServices()
    }

    /// Branches of a repository for the base-branch pickers; empty if it can't be read.
    func branches(inRepositoryAt path: String) async -> [GitWorktreeManager.Branch] {
        (try? await GitWorktreeManager(worktreeRoot: workspaceSettings.resolvedWorktreeRoot).branches(inRepositoryAt: path)) ?? []
    }

    /// The editor chosen in Settings, or the first installed one.
    var preferredEditor: EditorApp? {
        editors.first { $0.bundleID == workspaceSettings.editorBundleID } ?? editors.first
    }

    var resolvedClaudeExecutable: URL? {
        ClaudeCLI.resolve(configuredPath: agentSettings.claudePath)
    }

    // MARK: - Internals

    /// Runs `work` as the ticket's single background run, streaming its events into `activity`
    /// in order.
    private func launch(
        _ kind: AgentRun.Kind,
        ticketID: String,
        work: @escaping (@escaping @Sendable (RunEvent) -> Void) async throws -> Void
    ) {
        guard runTasks[ticketID] == nil else { return }
        let (events, continuation) = AsyncStream<RunEvent>.makeStream()
        activity[ticketID] = RunActivity(kind: kind, startedAt: Date())
        runTasks[ticketID] = Task {
            let consumer = Task {
                for await event in events {
                    switch event {
                    case .started:
                        await reload()
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
                try await work { continuation.yield($0) }
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

    private func persist<T: StoredSettings>(_ settings: T) {
        do {
            try settingsStore.save(settings)
        } catch {
            lastError = "Could not save settings: \(error.localizedDescription)"
        }
    }

    /// Runs already in progress keep the services they started with.
    private func rebuildServices() {
        services = Self.makeServices(
            database: orchestrator.database, workspace: workspaceSettings, agent: agentSettings, artifacts: artifacts
        )
    }

    /// Once per database file per launch: stops agent processes left over from a crash, then
    /// marks their runs failed. Runs are never resumed automatically.
    private func recoverIfNeeded() async {
        guard recoveredDatabasePath != databaseLocation else { return }
        recoveredDatabasePath = databaseLocation
        do {
            for group in try await orchestrator.database.unfinishedProcessGroups() {
                await ProcessRunner.terminateOrphanedGroup(group, expectedCommand: "claude")
            }
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

    private static func fillMissingCommandPresets(_ settings: inout WorkspaceSettings) -> Bool {
        var changed = false
        for index in settings.repositories.indices
        where settings.repositories[index].setupCommands.isEmpty && settings.repositories[index].agentCommands.isEmpty {
            let presets = CommandPresets.detect(repositoryAt: settings.repositories[index].path)
            settings.repositories[index].setupCommands = presets.setup
            settings.repositories[index].agentCommands = presets.agent
            changed = true
        }
        return changed
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

    private static func makeServices(
        database: AppDatabase,
        workspace: WorkspaceSettings,
        agent: AgentSettings,
        artifacts: ArtifactStore
    ) -> Services {
        let runner: any AgentRunner = if let executable = ClaudeCLI.resolve(configuredPath: agent.claudePath) {
            ClaudeCodeRunner(
                executable: executable, model: agent.model,
                investigationTimeout: .seconds(max(1, agent.investigationTimeoutMinutes) * 60),
                implementationTimeout: .seconds(max(1, agent.implementationTimeoutMinutes) * 60)
            )
        } else {
            UnavailableAgentRunner(reason: "Claude Code was not found. Set its location in Settings → Agent.")
        }
        let worktrees = GitWorktreeManager(worktreeRoot: workspace.resolvedWorktreeRoot)
        return Services(
            investigation: InvestigationService(database: database, worktrees: worktrees, runner: runner, artifacts: artifacts),
            implementation: ImplementationService(database: database, worktrees: worktrees, runner: runner, artifacts: artifacts)
        )
    }
}
