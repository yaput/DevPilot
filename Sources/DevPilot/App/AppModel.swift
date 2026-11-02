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

    var latestValidation: AgentRun? {
        runs.last { $0.validation != nil }
    }

    var latestReview: AgentRun? {
        runs.last { $0.review != nil }
    }
}

/// Live progress of an agent run in this app session.
struct RunActivity: Equatable {
    let kind: AgentRun.Kind
    var startedAt: Date
    var lines: [String] = []
    /// Set while waiting for a free slot (1 = next).
    var queuedPosition: Int?

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
        let verification: VerificationService
        /// nil when the agent can't drive a browser.
        let qa: QAService?
    }

    private let settingsStore: SettingsStore
    private let factory: ProviderFactory
    private var orchestrator: WorkflowOrchestrator
    private var services: Services
    private var recoveredDatabasePath: String?
    @ObservationIgnored private var runTasks: [String: Task<Void, Never>] = [:]
    /// Repository secrets and provider tokens. Only DevPilot's own code reads repository
    /// secrets; they are never given to an agent.
    @ObservationIgnored private let credentials: any CredentialStore
    @ObservationIgnored let localEnvironment = LocalEnvironment(stateDirectory: AppDatabase.defaultDirectory)
    /// The app running locally for one ticket, if any.
    private(set) var localRun: LocalRunStatus?
    @ObservationIgnored private var localRunTask: Task<Void, Never>?
    /// DevPilot's own Playwright install for signing in and QA sessions.
    @ObservationIgnored let qaTools = QATools(directory: AppDatabase.defaultDirectory.appending(path: "qa-tools", directoryHint: .isDirectory))
    private(set) var qaToolsInstalling = false
    /// Bumped after an install so views re-read `qaTools.isInstalled`.
    private(set) var qaToolsRevision = 0
    /// The last sign-in attempt for the current local run.
    private(set) var qaSignIn: QASignInState?
    /// The QA session running or last finished in this launch.
    private(set) var qaSession: QASessionState?
    @ObservationIgnored private var qaSessionTask: Task<Void, Never>?
    /// Investigations mostly wait on Claude; builds (implementation, tests, review) load the Mac.
    @ObservationIgnored private let investigationSlots: RunLimiter
    @ObservationIgnored private let buildSlots: RunLimiter

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
    /// Dashboard selection; several tickets can be selected for batch actions.
    var selection: Set<String> = []

    /// The single selected ticket, or nil when none or several are selected.
    var selectedTicketID: String? {
        get { selection.count == 1 ? selection.first : nil }
        set { selection = newValue.map { [$0] } ?? [] }
    }
    var lastError: String?

    private var started = false

    init(settingsStore: SettingsStore, factory: ProviderFactory, credentials: any CredentialStore) {
        self.settingsStore = settingsStore
        self.factory = factory
        self.credentials = credentials
        let settings = settingsStore.load(ProviderSettings.self)
        let agentSettings = settingsStore.load(AgentSettings.self)
        var workspaceSettings = settingsStore.load(WorkspaceSettings.self)
        // Repositories added before a kind of per-repository setting existed get its presets once.
        let filled = Self.fillMissingPresets(&workspaceSettings) { repositoryID, name, value in
            try? credentials.setSecret(value, for: .repository(repositoryID, name))
        }
        if filled {
            try? settingsStore.save(workspaceSettings)
        }
        self.settings = settings
        self.workspaceSettings = workspaceSettings
        self.agentSettings = agentSettings
        investigationSlots = RunLimiter(limit: agentSettings.maxParallelInvestigations)
        buildSlots = RunLimiter(limit: agentSettings.maxParallelBuilds)
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
        Notifier.shared.onOpenTicket = { [weak self] ticketID in
            self?.selectedTicketID = ticketID
        }
    }

    /// Synced providers, plus DevPilot's own once a local ticket exists (for the filter).
    var providerKinds: [TicketProviderKind] {
        orchestrator.providerKinds + (tickets.contains { $0.provider == .local } ? [.local] : [])
    }
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
    var readyForReviewCount: Int { states.values.filter { $0 == .readyForHumanReview }.count }
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
        // Leftovers of a local run interrupted by a crash: services, database copy, copied files.
        let credentials = self.credentials
        await localEnvironment.cleanUpLeftovers(tools: agentSettings.toolEnvironment) { repositoryID, name in
            (try? credentials.secret(for: .repository(repositoryID, name))) ?? nil
        }
        Notifier.shared.requestAuthorization()
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
        launch(.investigation, ticketID: ticketID, slots: investigationSlots) { onEvent in
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
        let verification = services.verification
        let fixAttempts = agentSettings.automaticFixAttempts
        launch(.implementation, ticketID: ticketID, slots: buildSlots) { [self] onEvent in
            if agentSettings.toolPath.isEmpty {
                onEvent(.progress("Importing PATH and JAVA_HOME from your login shell"))
            }
            let tools = try await ensureToolEnvironment()
            _ = try await service.implement(ticketID: ticketID, repository: repository, tools: tools, onEvent: onEvent)
            try await verification.verify(
                ticketID: ticketID, repository: repository, tools: tools, maxFixAttempts: fixAttempts, onEvent: onEvent
            )
        }
    }

    /// Runs validation and review (from `validating`, `reviewing`, or again from the hand-off).
    func startVerification(_ ticketID: String, repositoryID: String) {
        guard let repository = workspaceSettings.repository(id: repositoryID) else {
            lastError = "This ticket's repository is no longer in Settings → Repositories."
            return
        }
        let verification = services.verification
        let tools = agentSettings.toolEnvironment
        let fixAttempts = agentSettings.automaticFixAttempts
        launch(.validation, ticketID: ticketID, slots: buildSlots) { onEvent in
            try await verification.verify(
                ticketID: ticketID, repository: repository, tools: tools, maxFixAttempts: fixAttempts, onEvent: onEvent
            )
        }
    }

    /// The user asks Claude to fix specific things (failing tests, review findings), then
    /// validation and review run again.
    func fixWithClaude(_ ticketID: String, repositoryID: String, instructions: String) {
        guard let repository = workspaceSettings.repository(id: repositoryID) else {
            lastError = "This ticket's repository is no longer in Settings → Repositories."
            return
        }
        let implementation = services.implementation
        let verification = services.verification
        let tools = agentSettings.toolEnvironment
        let fixAttempts = agentSettings.automaticFixAttempts
        launch(.implementation, ticketID: ticketID, slots: buildSlots) { onEvent in
            _ = try await implementation.implement(
                ticketID: ticketID, repository: repository, tools: tools, fixInstructions: instructions, onEvent: onEvent
            )
            try await verification.verify(
                ticketID: ticketID, repository: repository, tools: tools, maxFixAttempts: fixAttempts, onEvent: onEvent
            )
        }
    }

    /// Marks the ticket done and, if asked, removes its worktree (refused by git if anything
    /// is uncommitted; the branch is kept unless fully merged or pushed).
    func markDone(_ ticketID: String, removeWorktree: Bool) async {
        do {
            try await orchestrator.database.markDone(ticketID: ticketID)
        } catch {
            lastError = error.localizedDescription
            await reload()
            return
        }
        if removeWorktree {
            await discardWorktree(ticketID)
        }
        await reload()
        detailRevision += 1
    }

    func branchStatus(_ ticketID: String) async -> BranchStatus? {
        guard let workspace = try? await orchestrator.database.workspace(ticketID: ticketID) else { return nil }
        return await GitWorktreeManager(worktreeRoot: workspaceSettings.resolvedWorktreeRoot).branchStatus(workspace)
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

    /// A clean slate: worktree (including uncommitted changes, the user confirmed), plans,
    /// answers, runs and transcripts are gone from view; the ticket is back at `selected`.
    func startOver(_ ticketID: String) async {
        guard !isRunning(ticketID) else { return }
        do {
            let service = StartOverService(
                database: orchestrator.database,
                worktrees: GitWorktreeManager(worktreeRoot: workspaceSettings.resolvedWorktreeRoot),
                artifacts: artifacts
            )
            if let branch = try await service.startOver(ticketID: ticketID) {
                lastError = "Started over. Branch \(branch) has commits, so it was kept; the new worktree gets a new branch."
            }
        } catch {
            lastError = "Could not start over: \(error.localizedDescription)"
        }
        await reload()
        detailRevision += 1
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
        guard settings != agentSettings else { return }
        // Concurrency limits can change any time; everything else waits until runs finish.
        var applied = hasActiveRuns ? agentSettings : settings
        applied.maxParallelInvestigations = settings.maxParallelInvestigations
        applied.maxParallelBuilds = settings.maxParallelBuilds
        persist(applied)
        agentSettings = applied
        Task {
            await investigationSlots.setLimit(applied.maxParallelInvestigations)
            await buildSlots.setLimit(applied.maxParallelBuilds)
        }
        if !hasActiveRuns { rebuildServices() }
    }

    /// PATH and JAVA_HOME for builds, imported from the login shell the first time they are needed.
    private func ensureToolEnvironment() async throws -> ToolEnvironment {
        guard agentSettings.toolPath.isEmpty else { return agentSettings.toolEnvironment }
        let tools = try await ToolEnvironment.importFromLoginShell()
        var updated = agentSettings
        updated.toolPath = tools.path
        updated.javaHome = tools.javaHome
        persist(updated)
        agentSettings = updated
        return tools
    }

    // MARK: - Local run

    /// Starts the ticket's app locally (one at a time): dependencies, a database copy, setup,
    /// then the repository's services from the ticket's worktree on DevPilot's own ports.
    func startLocalRun(ticketID: String, workspace: TicketWorkspace) {
        guard localRunTask == nil, localRun == nil || isFinished(localRun) else {
            lastError = "Another local run is active. Stop it first."
            return
        }
        guard let repository = workspaceSettings.repository(id: workspace.repositoryID), repository.localRun.isConfigured else {
            lastError = LocalRunError.notConfigured.localizedDescription
            return
        }
        let config = repository.localRun
        var secrets: [String: String] = [:]
        for name in config.secretNames {
            if let value = (try? credentials.secret(for: .repository(repository.id, name))) ?? nil {
                secrets[name] = value
            }
        }
        let setup = repository.setupCommands.filter(\.isEnabled).map(\.command)
        let optionalSetup = Set(repository.setupCommands.filter { $0.isEnabled && $0.isOptional }.map(\.command))
        let environment = localEnvironment
        let (updates, continuation) = AsyncStream<LocalRunStatus>.makeStream()
        localRunTask = Task {
            let consumer = Task {
                for await status in updates { localRun = status }
            }
            do {
                let tools = try await ensureToolEnvironment()
                _ = try await environment.start(
                    ticketID: ticketID, repositoryID: repository.id, worktree: workspace.worktreePath,
                    mainCheckout: repository.path, config: config, setupCommands: setup, optionalSetupCommands: optionalSetup,
                    secrets: secrets, tools: tools
                ) { continuation.yield($0) }
            } catch {
                lastError = "Local run failed: \(error.localizedDescription)"
            }
            continuation.finish()
            await consumer.value
            localRunTask = nil
        }
    }

    func stopLocalRun() async {
        if let session = qaSessionTask {
            session.cancel()
            await session.value
        }
        if let starting = localRunTask {
            // Still starting: cancelling makes `start` fail and clean up after itself. Calling
            // `stop` now would tear down underneath it.
            starting.cancel()
            await starting.value
        } else {
            await localEnvironment.stop()
        }
        localRun = nil
        qaSignIn = nil
    }

    func dismissLocalRunResult() {
        if isFinished(localRun) {
            localRun = nil
            qaSignIn = nil
        }
    }

    // MARK: - QA sign-in

    func installQATools() async {
        guard !qaToolsInstalling else { return }
        qaToolsInstalling = true
        defer {
            qaToolsInstalling = false
            qaToolsRevision += 1
        }
        do {
            try await qaTools.install(tools: ensureToolEnvironment())
        } catch {
            lastError = "Installing QA browser tools failed: \(error.localizedDescription)"
        }
    }

    /// Signs in to the running app with the repository's login script, as a QA session will.
    func testQASignIn(repositoryID: String) async {
        guard qaSignIn?.isSigningIn != true, let run = localRun, run.phase == .running,
              let repository = workspaceSettings.repository(id: repositoryID) else { return }
        _ = await signIn(run: run, repository: repository)
    }

    /// Signs in to `run` and records the attempt; nil if it failed (the reason is in `qaSignIn`).
    private func signIn(run: LocalRunStatus, repository: RepositoryConfig) async -> LoginResult? {
        guard let baseURL = run.appURL else { return nil }
        let config = repository.qa.login
        var secrets: [String: String] = [:]
        for name in config.secretNames {
            secrets[name] = (try? credentials.secret(for: .repository(repository.id, name))) ?? nil
        }
        qaSignIn = .signingIn(runID: run.runID)
        do {
            let result = try await LoginRunner.signIn(
                config: config, baseURL: baseURL, secrets: secrets, qaTools: qaTools,
                outputDirectory: run.qaLoginDirectory, tools: ensureToolEnvironment()
            )
            if localRun?.runID == run.runID { qaSignIn = .signedIn(runID: run.runID, result) }
            return result
        } catch {
            if localRun?.runID == run.runID {
                qaSignIn = .failed(runID: run.runID, message: error.localizedDescription, screenshot: (error as? LoginError)?.screenshotPath)
            }
            return nil
        }
    }

    // MARK: - QA sessions

    /// Explores the ticket's running app with the QA agent (signed in first when configured),
    /// then replays every reported bug. One session at a time.
    func startQASession(ticketID: String, repositoryID: String) {
        guard qaSessionTask == nil else { return }
        guard let qa = services.qa else {
            lastError = "QA sessions need Claude Code. Set its location in Settings → Agent."
            return
        }
        guard let run = localRun, run.ticketID == ticketID, run.phase == .running,
              let repository = workspaceSettings.repository(id: repositoryID) else {
            lastError = "Start the app with Run Locally first."
            return
        }
        guard qaTools.isInstalled else {
            lastError = LoginError.toolsNotInstalled.localizedDescription
            return
        }
        qaSession = QASessionState(ticketID: ticketID, phase: .running(["Preparing"]))
        let tools = qaTools
        qaSessionTask = Task {
            defer { qaSessionTask = nil }
            var signInResult: LoginResult?
            if repository.qa.login.isEnabled {
                appendQAProgress("Signing in")
                if case .signedIn(let runID, let result)? = qaSignIn, runID == run.runID,
                   FileManager.default.fileExists(atPath: result.storageStatePath) {
                    signInResult = result
                } else {
                    signInResult = await signIn(run: run, repository: repository)
                    if signInResult == nil, !Task.isCancelled {
                        // A cold app can be slow on its first sign-in requests.
                        appendQAProgress("Sign-in failed; trying once more")
                        signInResult = await signIn(run: run, repository: repository)
                    }
                }
                guard signInResult != nil else {
                    let reason = if case .failed(_, let message, _)? = qaSignIn { message } else { "sign-in failed" }
                    qaSession?.phase = .failed(reason)
                    return
                }
            }
            do {
                let result = try await qa.run(
                    ticketID: ticketID, localRun: run, signIn: signInResult, qaTools: tools, tools: ensureToolEnvironment(),
                    timeLimitMinutes: max(1, repository.qa.timeLimitMinutes)
                ) { [weak self] message in
                    Task { @MainActor in self?.appendQAProgress(message) }
                }
                qaSession?.phase = .finished(result)
                notifyQAFinished(ticketID: ticketID, result: result)
            } catch is CancellationError {
                qaSession?.phase = .failed("Cancelled.")
            } catch {
                qaSession?.phase = .failed(Task.isCancelled ? "Cancelled." : error.localizedDescription)
            }
        }
    }

    func cancelQASession() {
        qaSessionTask?.cancel()
    }

    /// Finished sessions of a ticket, newest first.
    func qaSessions(ticketID: String) -> [QASessionResult] {
        services.qa?.sessions(ticketID: ticketID) ?? []
    }

    private func appendQAProgress(_ message: String) {
        guard case .running(var messages)? = qaSession?.phase else { return }
        messages.append(message)
        qaSession?.phase = .running(Array(messages.suffix(200)))
    }

    private func notifyQAFinished(ticketID: String, result: QASessionResult) {
        let bugs = result.report.findings.count
        let name = tickets.first { $0.id == ticketID }.map { "\($0.externalID): \($0.title)" } ?? ticketID
        Notifier.shared.post(
            title: bugs == 0 ? "QA found no bugs" : "QA found \(bugs) bug\(bugs == 1 ? "" : "s") (\(result.confirmedCount) reproduced)",
            body: name, ticketID: ticketID
        )
    }

    private func isFinished(_ status: LocalRunStatus?) -> Bool {
        switch status?.phase {
        case .failed?, .stopped?: true
        default: false
        }
    }

    // MARK: - Repository secrets (Keychain)

    func hasRepositorySecret(_ repositoryID: String, _ name: String) -> Bool {
        ((try? credentials.secret(for: .repository(repositoryID, name))) ?? nil)?.isEmpty == false
    }

    /// For values that are fine to display, such as a test account's username. Never for passwords.
    func repositorySecret(_ repositoryID: String, _ name: String) -> String? {
        (try? credentials.secret(for: .repository(repositoryID, name))) ?? nil
    }

    func setRepositorySecret(_ repositoryID: String, _ name: String, value: String) {
        do {
            try credentials.setSecret(value, for: .repository(repositoryID, name))
        } catch {
            lastError = error.localizedDescription
        }
    }

    func deleteRepositorySecret(_ repositoryID: String, _ name: String) {
        try? credentials.deleteSecret(for: .repository(repositoryID, name))
    }

    /// Investigates several tickets at once (up to the parallel-investigation limit; the rest
    /// queue). Discovered tickets are selected first. Returns the tickets that were skipped and why.
    @discardableResult
    func investigateBatch(_ ticketIDs: [String]) async -> [(ticket: Ticket, reason: String)] {
        var skipped: [(Ticket, String)] = []
        for id in ticketIDs {
            guard let ticket = tickets.first(where: { $0.id == id }) else { continue }
            guard let repository = workspaceSettings.suggestedRepository(for: ticket) else {
                skipped.append((ticket, "no repository rule matches"))
                continue
            }
            guard !isRunning(id) else {
                skipped.append((ticket, "already running"))
                continue
            }
            if state(of: id) == .discovered {
                await select(id)
            }
            guard [.selected, .needsRevision].contains(state(of: id)) else {
                skipped.append((ticket, "is \(state(of: id).displayName.lowercased())"))
                continue
            }
            startInvestigation(id, repositoryID: repository.id)
        }
        return skipped
    }

    /// Selected tickets an action applies to: each is at the right stage and not running.
    func eligible(_ action: BulkAction, among ticketIDs: [String]) -> [Ticket] {
        tickets.filter { ticketIDs.contains($0.id) }.filter { ticket in
            let state = state(of: ticket.id)
            switch action {
            case .investigate: return [.discovered, .selected, .needsRevision].contains(state) && !isRunning(ticket.id)
            case .approvePlans, .approveAndImplement: return state == .awaitingPlanApproval && !isRunning(ticket.id)
            case .implement: return state == .approved && !isRunning(ticket.id)
            case .verify: return [.validating, .reviewing, .readyForHumanReview].contains(state) && !isRunning(ticket.id)
            case .stop: return isRunning(ticket.id)
            }
        }
    }

    /// Runs `action` on every eligible selected ticket (runs queue behind the parallel limits).
    /// Returns the tickets that were skipped and why.
    @discardableResult
    func perform(_ action: BulkAction, on ticketIDs: [String]) async -> [(ticket: Ticket, reason: String)] {
        let targets = eligible(action, among: ticketIDs)
        var skipped = tickets.filter { ticketIDs.contains($0.id) && !targets.map(\.id).contains($0.id) }.map {
            ($0, isRunning($0.id) && action != .stop ? "is running" : "is \(state(of: $0.id).displayName.lowercased())")
        }
        switch action {
        case .investigate:
            skipped += await investigateBatch(targets.map(\.id))
        case .stop:
            targets.forEach { stopRun($0.id) }
        case .approvePlans, .approveAndImplement:
            for ticket in targets {
                guard let document = try? await orchestrator.database.latestDecisionDocument(ticketID: ticket.id) else {
                    skipped.append((ticket, "has no plan"))
                    continue
                }
                await decide(ticket.id, decision: .approved, planHash: document.contentHash, notes: "Approved from a multi-selection")
            }
            if action == .approveAndImplement {
                skipped += await implementAll(eligible(.implement, among: targets.map(\.id)))
            }
        case .implement:
            skipped += await implementAll(targets)
        case .verify:
            for ticket in targets {
                guard let repositoryID = await repositoryID(of: ticket) else {
                    skipped.append((ticket, "its repository is not in Settings"))
                    continue
                }
                startVerification(ticket.id, repositoryID: repositoryID)
            }
        }
        return skipped
    }

    private func implementAll(_ targets: [Ticket]) async -> [(ticket: Ticket, reason: String)] {
        var skipped: [(Ticket, String)] = []
        for ticket in targets {
            guard let repositoryID = await repositoryID(of: ticket) else {
                skipped.append((ticket, "its repository is not in Settings"))
                continue
            }
            startImplementation(ticket.id, repositoryID: repositoryID)
        }
        return skipped
    }

    /// The repository of the ticket's worktree, else the routed one.
    private func repositoryID(of ticket: Ticket) async -> String? {
        let id = (try? await orchestrator.database.workspace(ticketID: ticket.id))?.repositoryID
            ?? workspaceSettings.suggestedRepository(for: ticket)?.id
        return id.flatMap { workspaceSettings.repository(id: $0)?.id }
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
    /// Events a run reports to the UI: the service's own, plus waiting for a slot.
    private enum ActivityEvent: Sendable {
        case run(RunEvent)
        case queued(position: Int)
        case slotAcquired
    }

    private func launch(
        _ kind: AgentRun.Kind,
        ticketID: String,
        slots: RunLimiter,
        work: @escaping @MainActor @Sendable (@escaping @Sendable (RunEvent) -> Void) async throws -> Void
    ) {
        guard runTasks[ticketID] == nil else { return }
        let (events, continuation) = AsyncStream<ActivityEvent>.makeStream()
        activity[ticketID] = RunActivity(kind: kind, startedAt: Date())
        runTasks[ticketID] = Task {
            let consumer = Task {
                for await event in events {
                    switch event {
                    case .queued(let position):
                        if var run = activity[ticketID] {
                            run.queuedPosition = position
                            activity[ticketID] = run
                        }
                    case .slotAcquired:
                        if var run = activity[ticketID], run.queuedPosition != nil {
                            run.queuedPosition = nil
                            run.startedAt = Date()
                            activity[ticketID] = run
                        }
                    case .run(.started):
                        await reload()
                    case .run(.progress(let line)):
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
                try await slots.withSlot(onQueued: { continuation.yield(.queued(position: $0)) }) {
                    continuation.yield(.slotAcquired)
                    try await work { continuation.yield(.run($0)) }
                }
            } catch is CancellationError {
                // Recorded as cancelled by the service.
            } catch {
                lastError = error.localizedDescription
            }
            continuation.finish()
            await consumer.value
            // From a fresh task: after Stop this one is cancelled, and GRDB refuses to read from
            // a cancelled task, so reload() would fail with CancellationError.
            await Task {
                runTasks[ticketID] = nil
                activity[ticketID] = nil
                await reload()
                detailRevision += 1
                notifyOutcome(ticketID)
            }.value
        }
    }

    /// Plan ready, clarification needed, ready for review, or failure.
    private func notifyOutcome(_ ticketID: String) {
        guard let ticket = tickets.first(where: { $0.id == ticketID }) else { return }
        let name = "\(ticket.externalID): \(ticket.title)"
        switch state(of: ticketID) {
        case .awaitingPlanApproval:
            Notifier.shared.post(title: "Plan ready for approval", body: name, ticketID: ticketID)
        case .needsClarification:
            Notifier.shared.post(title: "Clarification needed", body: name, ticketID: ticketID)
        case .readyForHumanReview:
            Notifier.shared.post(title: "Ready for your review", body: name, ticketID: ticketID)
        case .failed:
            Notifier.shared.post(title: "Run failed", body: name, ticketID: ticketID)
        default:
            break
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

    /// Creates a ticket in DevPilot (no tracker) for `repositoryID` and selects it.
    func createLocalTicket(title: String, description: String, acceptanceCriteria: [String], type: TicketType, repositoryID: String) async {
        do {
            let ticket = try await orchestrator.database.addLocalTicket(
                title: title, description: description, acceptanceCriteria: acceptanceCriteria, type: type, repositoryID: repositoryID
            )
            await reload()
            selection = [ticket.id]
        } catch {
            lastError = "Could not create the ticket: \(error.localizedDescription)"
        }
    }

    private func reload() async {
        do {
            tickets = try await orchestrator.database.tickets()
            states = try await orchestrator.database.workflowStates()
            unassignedIDs = try await orchestrator.database.unassignedTicketIDs()
        } catch {
            lastError = "Could not load tickets: \(error)"
        }
        let visible = Set(tickets.map(\.id))
        if !selection.isSubset(of: visible) {
            selection.formIntersection(visible)
        }
    }

    private static func fillMissingPresets(
        _ settings: inout WorkspaceSettings,
        storeSecret: (String, String, String) -> Void
    ) -> Bool {
        var changed = false
        if settings.presetsVersion < 2 {
            for index in settings.repositories.indices where !settings.repositories[index].localRun.isConfigured {
                let (config, secrets) = LocalRunPresets.detect(repositoryAt: settings.repositories[index].path)
                settings.repositories[index].localRun = config
                for (name, value) in secrets {
                    storeSecret(settings.repositories[index].id, name, value)
                }
            }
            changed = true
        }
        for index in settings.repositories.indices {
            let repository = settings.repositories[index]
            let needsCommands = repository.setupCommands.isEmpty && repository.agentCommands.isEmpty
            let needsValidation = settings.presetsVersion < 1 && repository.validationCommands.isEmpty
            guard needsCommands || needsValidation else { continue }
            let presets = CommandPresets.detect(repositoryAt: repository.path)
            if needsCommands {
                settings.repositories[index].setupCommands = presets.setup
                settings.repositories[index].agentCommands = presets.agent
            }
            if needsValidation || needsCommands {
                settings.repositories[index].validationCommands = presets.validation
            }
            changed = true
        }
        if settings.presetsVersion < 3 {
            for index in settings.repositories.indices where settings.repositories[index].qa.login.script.isEmpty {
                settings.repositories[index].qa.login = LoginPresets.detect(repositoryAt: settings.repositories[index].path)
            }
            settings.presetsVersion = 3
            changed = true
        }
        if settings.presetsVersion < 5 {
            // Schema files that migrations rewrite on every run.
            for index in settings.repositories.indices where settings.repositories[index].localRun.restoreFiles.isEmpty {
                let detected = LocalRunPresets.detect(repositoryAt: settings.repositories[index].path).config.restoreFiles
                settings.repositories[index].localRun.restoreFiles = detected
            }
        }
        if settings.presetsVersion < 4 {
            // A run's own ports for localhost URLs in .env files.
            for index in settings.repositories.indices {
                LocalRunPresets.addLocalhostOverrides(to: &settings.repositories[index].localRun, repositoryAt: settings.repositories[index].path)
            }
            settings.presetsVersion = 4
            changed = true
        }
        if settings.presetsVersion < 5 {
            settings.presetsVersion = 5
            changed = true
        }
        if settings.presetsVersion < 6 {
            // The form preset now waits for the page to settle; update scripts nobody edited.
            for index in settings.repositories.indices {
                let login = settings.repositories[index].qa.login
                if login.script.trimmingCharacters(in: .whitespacesAndNewlines)
                    == LoginPresets.previousForm(loginPath: login.loginPath).trimmingCharacters(in: .whitespacesAndNewlines) {
                    settings.repositories[index].qa.login.script = LoginPresets.form(loginPath: login.loginPath)
                }
            }
            settings.presetsVersion = 6
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
        let implementation = ImplementationService(database: database, worktrees: worktrees, runner: runner, artifacts: artifacts)
        let qa = (runner as? any QARunner).map { QAService(database: database, worktrees: worktrees, runner: $0, artifacts: artifacts) }
        return Services(
            investigation: InvestigationService(database: database, worktrees: worktrees, runner: runner, artifacts: artifacts),
            implementation: implementation,
            verification: VerificationService(
                database: database, worktrees: worktrees, runner: runner, implementation: implementation,
                validationTimeout: .seconds(max(1, agent.validationTimeoutMinutes) * 60), artifacts: artifacts
            ),
            qa: qa
        )
    }
}

/// A sign-in attempt against one local run.
enum QASignInState: Equatable {
    case signingIn(runID: String)
    case signedIn(runID: String, LoginResult)
    case failed(runID: String, message: String, screenshot: String?)

    var isSigningIn: Bool {
        if case .signingIn = self { return true }
        return false
    }
}

/// A QA session for one ticket: running with its progress, or its outcome.
struct QASessionState: Equatable {
    enum Phase: Equatable {
        case running([String])
        case finished(QASessionResult)
        case failed(String)
    }

    let ticketID: String
    var phase: Phase

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }
}

/// Actions on several selected tickets at once.
enum BulkAction: CaseIterable {
    case investigate, approvePlans, approveAndImplement, implement, verify, stop

    var title: String {
        switch self {
        case .investigate: "Investigate"
        case .approvePlans: "Approve Plans"
        case .approveAndImplement: "Approve & Implement"
        case .implement: "Implement"
        case .verify: "Run Tests & Review"
        case .stop: "Stop"
        }
    }

    var systemImage: String {
        switch self {
        case .investigate: "magnifyingglass"
        case .approvePlans: "checkmark.seal"
        case .approveAndImplement: "hammer.circle"
        case .implement: "hammer"
        case .verify: "checklist"
        case .stop: "stop.circle"
        }
    }

    /// Approving plans nobody opened deserves a second look.
    var needsConfirmation: Bool { self == .approvePlans || self == .approveAndImplement }
}
