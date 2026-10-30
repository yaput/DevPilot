import Foundation
import Synchronization
import Testing
@testable import DevPilotCore

struct InvestigationServiceTests {
    let repo: TestRepository
    let db: AppDatabase
    let artifacts: ArtifactStore
    let ticket = Ticket.sample()

    init() async throws {
        repo = try await TestRepository(files: ["README.md": "# Payments\n", "Sources/Webhooks.swift": "func deliver() {}\n"])
        db = try AppDatabase.inMemory()
        artifacts = ArtifactStore(root: repo.root.appending(path: "artifacts", directoryHint: .isDirectory))
        try await db.recordSync([ticket], for: .jira)
        try await db.transition(ticketID: ticket.id, to: .selected, message: "")
    }

    func service(_ runner: any AgentRunner) -> InvestigationService {
        InvestigationService(database: db, worktrees: repo.manager, runner: runner, artifacts: artifacts)
    }

    @Test func readyPlanAwaitsApprovalWithWorktreeAndArtifacts() async throws {
        defer { repo.remove() }
        let runner = FakeAgentRunner { _ in .sample() }
        let events = Mutex<[String]>([])

        let document = try await service(runner).investigate(ticketID: ticket.id, repository: repo.config) { event in
            events.withLock {
                switch event {
                case .started: $0.append("started")
                case .progress(let message): $0.append(message)
                }
            }
        }

        #expect(document.version == 1)
        #expect(document.investigation == .sample())
        #expect(try await db.state(of: ticket.id) == .awaitingPlanApproval)
        #expect(events.withLock { $0 } == ["started", "Preparing worktree", "Reading README.md"])

        let workspace = try #require(try await db.workspace(ticketID: ticket.id))
        #expect(workspace.branch == "devpilot/jira-plat-182")
        #expect(runner.requests.first?.workspace.worktreePath == workspace.worktreePath)
        #expect(FileManager.default.fileExists(atPath: workspace.worktreePath))

        let file = artifacts.decisionURL(for: document)
        #expect(try String(contentsOf: file, encoding: .utf8) == document.markdown)
        #expect(!file.path.hasPrefix(workspace.worktreePath))

        let run = try #require(try await db.runs(ticketID: ticket.id).first)
        #expect(run.outcome == .succeeded)
        #expect(run.numTurns == 3)
        #expect(run.logPath.hasPrefix(artifacts.root.path))
    }

    @Test func clarificationBlocksApprovalUntilAnswered() async throws {
        defer { repo.remove() }
        let runner = FakeAgentRunner { request in
            request.guidance.isEmpty ? .sample(outcome: .needsClarification, questions: ["Which endpoints?"]) : .sample()
        }

        let first = try await service(runner).investigate(ticketID: ticket.id, repository: repo.config) { _ in }
        #expect(try await db.state(of: ticket.id) == .needsClarification)
        await #expect(throws: WorkflowError.self) {
            _ = try await db.recordApproval(ticketID: ticket.id, decision: .approved, planHash: first.contentHash, notes: "")
        }

        try await db.recordClarification(ticketID: ticket.id, answers: "Only /v1/webhooks")
        let second = try await service(runner).investigate(ticketID: ticket.id, repository: repo.config) { _ in }

        #expect(second.version == 2)
        #expect(try await db.state(of: ticket.id) == .awaitingPlanApproval)
        let request = try #require(runner.requests.last)
        #expect(request.guidance == ["Answers to clarifying questions: Only /v1/webhooks"])
        #expect(request.previousPlan?.version == 1)
        // Same worktree is reused for the follow-up investigation.
        #expect(runner.requests[0].workspace.worktreePath == runner.requests[1].workspace.worktreePath)
        #expect(runner.requests[0].workspace.branch == runner.requests[1].workspace.branch)
    }

    @Test func revisionNotesReachTheNextInvestigation() async throws {
        defer { repo.remove() }
        let runner = FakeAgentRunner { _ in .sample() }
        let v1 = try await service(runner).investigate(ticketID: ticket.id, repository: repo.config) { _ in }
        _ = try await db.recordApproval(ticketID: ticket.id, decision: .revisionRequested, planHash: v1.contentHash, notes: "Add a metric")

        _ = try await service(runner).investigate(ticketID: ticket.id, repository: repo.config) { _ in }

        #expect(runner.requests.last?.guidance == ["Revision requested: Add a metric"])
        #expect(try await db.state(of: ticket.id) == .awaitingPlanApproval)
    }

    @Test func agentFailureMarksTicketFailed() async throws {
        defer { repo.remove() }
        let runner = FakeAgentRunner { _ in throw AgentError.failed("model overloaded") }

        await #expect(throws: AgentError.failed("model overloaded")) {
            _ = try await service(runner).investigate(ticketID: ticket.id, repository: repo.config) { _ in }
        }
        #expect(try await db.state(of: ticket.id) == .failed)
        let run = try #require(try await db.runs(ticketID: ticket.id).first)
        #expect(run.outcome == .failed)
        #expect(run.errorMessage == "The agent failed: model overloaded")
    }

    @Test func cancellationMarksTicketCancelled() async throws {
        defer { repo.remove() }
        let runner = FakeAgentRunner { _ in
            try await Task.sleep(for: .seconds(30))
            return .sample()
        }
        let svc = service(runner)
        let task = Task { try await svc.investigate(ticketID: ticket.id, repository: repo.config) { _ in } }
        try await Task.sleep(for: .milliseconds(500))
        task.cancel()

        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(try await db.state(of: ticket.id) == .cancelled)
        #expect(try await db.runs(ticketID: ticket.id).first?.outcome == .cancelled)
    }

    @Test func secondStartWhileRunningIsRejected() async throws {
        defer { repo.remove() }
        let gate = Mutex(false)
        let runner = FakeAgentRunner { _ in
            while !gate.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(20)) }
            return .sample()
        }
        let svc = service(runner)
        let first = Task { try await svc.investigate(ticketID: ticket.id, repository: repo.config) { _ in } }
        try await Task.sleep(for: .milliseconds(300))

        await #expect(throws: WorkflowError.illegalTransition(from: .investigating, to: .investigating)) {
            _ = try await svc.investigate(ticketID: ticket.id, repository: repo.config) { _ in }
        }
        gate.withLock { $0 = true }
        _ = try await first.value
        #expect(try await db.runs(ticketID: ticket.id).count == 1)
    }

    @Test func badRepositoryFailsBeforeTheAgentRuns() async throws {
        defer { repo.remove() }
        let runner = FakeAgentRunner { _ in .sample() }
        var config = repo.config
        config.baseBranch = "does-not-exist"

        await #expect(throws: WorkspaceError.baseBranchMissing("does-not-exist")) {
            _ = try await service(runner).investigate(ticketID: ticket.id, repository: config) { _ in }
        }
        #expect(runner.requests.isEmpty)
        #expect(try await db.state(of: ticket.id) == .failed)
    }

    @Test func interruptedRunIsClosedOnRecovery() async throws {
        defer { repo.remove() }
        let runID = try await db.beginRun(.investigation, ticketID: ticket.id, entering: .investigating, logPath: "/tmp/x", message: "")

        _ = try await db.failInterruptedRuns(message: "Interrupted")

        let run = try #require(try await db.runs(ticketID: ticket.id).first { $0.id == runID })
        #expect(run.outcome == .interrupted)
        #expect(try await db.state(of: ticket.id) == .failed)
    }

    @Test func clarificationOnlyAcceptedWhenAsked() async throws {
        defer { repo.remove() }
        await #expect(throws: WorkflowError.illegalTransition(from: .selected, to: .investigating)) {
            try await db.recordClarification(ticketID: ticket.id, answers: "x")
        }
    }
}

struct WorkspaceSettingsTests {
    func jira(_ key: String) -> Ticket { .sample(key) }

    @Test func projectRuleBeatsProviderDefault() {
        var settings = WorkspaceSettings()
        settings.repositories = [
            RepositoryConfig(id: "a", name: "API", path: "/a", baseBranch: "main"),
            RepositoryConfig(id: "b", name: "Mobile", path: "/b", baseBranch: "main"),
        ]
        settings.rules = [
            RepositoryRule(provider: .jira, projectKey: "", repositoryID: "a"),
            RepositoryRule(provider: .jira, projectKey: "mob", repositoryID: "b"),
        ]
        #expect(settings.suggestedRepository(for: jira("MOB-77"))?.id == "b")
        #expect(settings.suggestedRepository(for: jira("PLAT-1"))?.id == "a")
    }

    @Test func singleRepositoryIsTheFallback() {
        var settings = WorkspaceSettings()
        #expect(settings.suggestedRepository(for: jira("X-1")) == nil)
        settings.repositories = [RepositoryConfig(id: "only", name: "Only", path: "/o", baseBranch: "main")]
        #expect(settings.suggestedRepository(for: jira("X-1"))?.id == "only")
    }

    @Test func worktreeRootExpandsTilde() {
        #expect(WorkspaceSettings().resolvedWorktreeRoot.path == NSHomeDirectory() + "/DevPilot/worktrees")
    }

    @Test func decodingToleratesMissingKeys() throws {
        let settings = try JSONDecoder().decode(WorkspaceSettings.self, from: Data(#"{"worktreeRoot": "/x"}"#.utf8))
        #expect(settings.worktreeRoot == "/x")
        #expect(settings.repositories.isEmpty)
        let agent = try JSONDecoder().decode(AgentSettings.self, from: Data(#"{"model": "opus"}"#.utf8))
        #expect(agent.model == "opus")
        #expect(agent.investigationTimeoutMinutes == 20)
    }
}
