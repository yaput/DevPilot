import Foundation
import GRDB

/// SQLite store for tickets, workflow state, decision documents, approvals and the audit trail.
/// Lives in Application Support, outside any agent-writable worktree.
///
/// Every state change goes through `applyTransition` inside a single write transaction,
/// together with its audit event, so a crash can never leave state and history out of sync.
public final class AppDatabase: Sendable {
    let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    public static func onDisk(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try AppDatabase(DatabasePool(path: url.path))
    }

    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    public static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "DevPilot", directoryHint: .isDirectory)
    }

    // MARK: - Schema

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE ticket (
                    id TEXT PRIMARY KEY NOT NULL,
                    provider TEXT NOT NULL,
                    source TEXT NOT NULL,
                    externalID TEXT NOT NULL,
                    title TEXT NOT NULL,
                    description TEXT NOT NULL,
                    status TEXT NOT NULL,
                    assignee TEXT,
                    url TEXT NOT NULL,
                    commentsJSON TEXT NOT NULL,
                    acceptanceCriteriaJSON TEXT NOT NULL,
                    fetchedAt REAL NOT NULL,
                    -- 0 once the provider stops returning the ticket (reassigned, done, or another site).
                    isAssigned INTEGER NOT NULL DEFAULT 1,
                    UNIQUE (provider, source, externalID)
                );
                CREATE TABLE ticketWorkflow (
                    ticketID TEXT PRIMARY KEY NOT NULL REFERENCES ticket(id) ON DELETE CASCADE,
                    state TEXT NOT NULL,
                    updatedAt REAL NOT NULL
                );
                CREATE TABLE workflowEvent (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    ticketID TEXT NOT NULL REFERENCES ticket(id),
                    kind TEXT NOT NULL,
                    fromState TEXT,
                    toState TEXT,
                    message TEXT NOT NULL,
                    createdAt REAL NOT NULL
                );
                CREATE INDEX workflowEvent_ticketID ON workflowEvent(ticketID, id);
                CREATE TABLE decisionDocument (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    ticketID TEXT NOT NULL REFERENCES ticket(id),
                    version INTEGER NOT NULL,
                    markdown TEXT NOT NULL,
                    contentHash TEXT NOT NULL,
                    createdAt REAL NOT NULL,
                    UNIQUE (ticketID, version)
                );
                CREATE TABLE approval (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    ticketID TEXT NOT NULL REFERENCES ticket(id),
                    planHash TEXT NOT NULL,
                    decision TEXT NOT NULL,
                    notes TEXT NOT NULL,
                    decidedAt REAL NOT NULL
                );
                """)
        }
        migrator.registerMigration("v2-workspaces-and-runs") { db in
            try db.execute(sql: """
                CREATE TABLE ticketWorkspace (
                    ticketID TEXT PRIMARY KEY NOT NULL REFERENCES ticket(id),
                    repositoryID TEXT NOT NULL,
                    repositoryName TEXT NOT NULL,
                    repositoryPath TEXT NOT NULL,
                    baseBranch TEXT NOT NULL,
                    baseCommit TEXT NOT NULL,
                    branch TEXT NOT NULL,
                    worktreePath TEXT NOT NULL UNIQUE,
                    createdAt REAL NOT NULL
                );
                CREATE TABLE agentRun (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    ticketID TEXT NOT NULL REFERENCES ticket(id),
                    kind TEXT NOT NULL,
                    startedAt REAL NOT NULL,
                    finishedAt REAL,
                    outcome TEXT,
                    numTurns INTEGER,
                    costUSD REAL,
                    logPath TEXT NOT NULL,
                    errorMessage TEXT
                );
                CREATE INDEX agentRun_ticketID ON agentRun(ticketID, id);
                ALTER TABLE decisionDocument ADD COLUMN investigationJSON TEXT;
                """)
        }
        migrator.registerMigration("v3-ticket-type-and-implementation") { db in
            try db.execute(sql: """
                ALTER TABLE ticket ADD COLUMN type TEXT NOT NULL DEFAULT 'feature';
                ALTER TABLE agentRun ADD COLUMN reportJSON TEXT;
                ALTER TABLE agentRun ADD COLUMN processGroup INTEGER;
                """)
        }
        migrator.registerMigration("v4-attempts") { db in
            // History is scoped to an attempt; "Start Over" begins a new one. Older attempts stay
            // in the database as an audit trail but are no longer shown or used as context.
            try db.execute(sql: """
                ALTER TABLE ticketWorkflow ADD COLUMN attempt INTEGER NOT NULL DEFAULT 1;
                ALTER TABLE workflowEvent ADD COLUMN attempt INTEGER NOT NULL DEFAULT 1;
                ALTER TABLE agentRun ADD COLUMN attempt INTEGER NOT NULL DEFAULT 1;
                ALTER TABLE approval ADD COLUMN attempt INTEGER NOT NULL DEFAULT 1;
                CREATE TABLE decisionDocumentNew (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    ticketID TEXT NOT NULL REFERENCES ticket(id),
                    attempt INTEGER NOT NULL DEFAULT 1,
                    version INTEGER NOT NULL,
                    markdown TEXT NOT NULL,
                    contentHash TEXT NOT NULL,
                    createdAt REAL NOT NULL,
                    investigationJSON TEXT,
                    UNIQUE (ticketID, attempt, version)
                );
                INSERT INTO decisionDocumentNew (id, ticketID, attempt, version, markdown, contentHash, createdAt, investigationJSON)
                    SELECT id, ticketID, 1, version, markdown, contentHash, createdAt, investigationJSON FROM decisionDocument;
                DROP TABLE decisionDocument;
                ALTER TABLE decisionDocumentNew RENAME TO decisionDocument;
                """)
        }
        return migrator
    }

    /// SQL for the ticket's current attempt; bind the ticket ID where it appears.
    private static let currentAttempt = "(SELECT attempt FROM ticketWorkflow WHERE ticketWorkflow.ticketID = ?)"

    // MARK: - Tickets

    /// Records the complete set of tickets a provider currently assigns to the user: inserts or
    /// refreshes them, and marks that provider's other tickets as no longer assigned. Newly seen
    /// tickets start in `discovered`; existing tickets keep their workflow state.
    public func recordSync(_ tickets: [Ticket], for provider: TicketProviderKind) async throws {
        precondition(tickets.allSatisfy { $0.provider == provider }, "Tickets must belong to \(provider)")
        try await writer.write { db in
            for ticket in tickets {
                try db.execute(
                    sql: """
                        INSERT INTO ticket (id, provider, source, externalID, title, description, status, assignee, url,
                                            commentsJSON, acceptanceCriteriaJSON, fetchedAt, isAssigned, type)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?)
                        ON CONFLICT(id) DO UPDATE SET
                            title = excluded.title, description = excluded.description, status = excluded.status,
                            assignee = excluded.assignee, url = excluded.url, commentsJSON = excluded.commentsJSON,
                            acceptanceCriteriaJSON = excluded.acceptanceCriteriaJSON, fetchedAt = excluded.fetchedAt,
                            isAssigned = 1, type = excluded.type
                        """,
                    arguments: [
                        ticket.id, ticket.provider.rawValue, ticket.source, ticket.externalID, ticket.title,
                        ticket.description, ticket.status, ticket.assignee, ticket.url.absoluteString,
                        try Self.json(ticket.comments), try Self.json(ticket.acceptanceCriteria),
                        ticket.fetchedAt.timeIntervalSince1970, ticket.type.rawValue,
                    ]
                )
                let isNew = try Self.fetchState(db, ticketID: ticket.id) == nil
                if isNew {
                    let now = Date()
                    try db.execute(
                        sql: "INSERT INTO ticketWorkflow (ticketID, state, updatedAt) VALUES (?, ?, ?)",
                        arguments: [ticket.id, WorkflowState.discovered.rawValue, now.timeIntervalSince1970]
                    )
                    try Self.insertEvent(
                        db, ticketID: ticket.id, kind: .transition, from: nil, to: .discovered,
                        message: "Discovered via \(ticket.provider.displayName) sync", at: now
                    )
                }
            }
            try db.execute(sql: "CREATE TEMP TABLE IF NOT EXISTS syncedTicket (id TEXT PRIMARY KEY)")
            try db.execute(sql: "DELETE FROM syncedTicket")
            for ticket in tickets {
                try db.execute(sql: "INSERT INTO syncedTicket (id) VALUES (?)", arguments: [ticket.id])
            }
            try db.execute(
                sql: "UPDATE ticket SET isAssigned = 0 WHERE provider = ? AND id NOT IN (SELECT id FROM syncedTicket)",
                arguments: [provider.rawValue]
            )
        }
    }

    /// Tickets to show on the dashboard: currently assigned ones, plus unassigned ones that are
    /// still mid-workflow so in-progress work never silently disappears.
    public func tickets() async throws -> [Ticket] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT ticket.* FROM ticket JOIN ticketWorkflow ON ticketWorkflow.ticketID = ticket.id
                WHERE ticket.isAssigned = 1 OR ticketWorkflow.state NOT IN (\(Self.inactiveStatesSQL))
                ORDER BY ticket.provider, ticket.source, ticket.externalID
                """).map(Self.ticket(from:))
        }
    }

    public func unassignedTicketIDs() async throws -> Set<String> {
        try await writer.read { db in
            Set(try String.fetchAll(db, sql: "SELECT id FROM ticket WHERE isAssigned = 0"))
        }
    }

    /// States in which an unassigned ticket has nothing left to show.
    private static let inactiveStatesSQL = [WorkflowState.discovered, .cancelled, .rejected, .completeManual]
        .map { "'\($0.rawValue)'" }
        .joined(separator: ",")

    // MARK: - Workflow state

    public func workflowStates() async throws -> [String: WorkflowState] {
        try await writer.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT ticketID, state FROM ticketWorkflow")
            var states: [String: WorkflowState] = [:]
            for row in rows {
                states[row["ticketID"]] = WorkflowState(rawValue: row["state"])
            }
            return states
        }
    }

    public func state(of ticketID: String) async throws -> WorkflowState? {
        try await writer.read { db in try Self.fetchState(db, ticketID: ticketID) }
    }

    public func transition(ticketID: String, to next: WorkflowState, message: String) async throws {
        try await writer.write { db in
            try Self.applyTransition(db, ticketID: ticketID, to: next, kind: .transition, message: message)
        }
    }

    /// Moves every ticket that was mid-run when the app last stopped to `failed`.
    /// Runs are never resumed automatically; the user has to restart them explicitly.
    public func failInterruptedRuns(message: String) async throws -> [String] {
        try await writer.write { db in
            // Tickets in a running state, or with a run that never finished (validation and
            // review run while the ticket rests in `validating` / `reviewing`).
            let running = WorkflowState.allCases.filter(\.isAgentRunning).map(\.rawValue)
            let ids = try String.fetchAll(
                db,
                sql: """
                    SELECT ticketID FROM ticketWorkflow
                    WHERE state IN (\(running.map { _ in "?" }.joined(separator: ",")))
                       OR (ticketID IN (SELECT ticketID FROM agentRun WHERE finishedAt IS NULL)
                           AND state NOT IN ('failed', 'cancelled', 'complete_manual'))
                    """,
                arguments: StatementArguments(running)
            )
            for id in ids where try Self.fetchState(db, ticketID: id)?.canTransition(to: .failed) == true {
                try Self.applyTransition(db, ticketID: id, to: .failed, kind: .transition, message: message)
            }
            try db.execute(
                sql: "UPDATE agentRun SET finishedAt = ?, outcome = ?, errorMessage = ? WHERE finishedAt IS NULL",
                arguments: [Date().timeIntervalSince1970, AgentRun.Outcome.interrupted.rawValue, message]
            )
            return ids
        }
    }

    public func events(ticketID: String) async throws -> [WorkflowEvent] {
        try await writer.read { db in
            try Row.fetchAll(
                db, sql: "SELECT * FROM workflowEvent WHERE ticketID = ? AND attempt = \(Self.currentAttempt) ORDER BY id",
                arguments: [ticketID, ticketID]
            )
                .map { row in
                    WorkflowEvent(
                        id: row["id"],
                        ticketID: row["ticketID"],
                        kind: WorkflowEvent.Kind(rawValue: row["kind"]) ?? .transition,
                        fromState: (row["fromState"] as String?).flatMap(WorkflowState.init(rawValue:)),
                        toState: (row["toState"] as String?).flatMap(WorkflowState.init(rawValue:)),
                        message: row["message"],
                        createdAt: Date(timeIntervalSince1970: row["createdAt"])
                    )
                }
        }
    }

    // MARK: - Decision documents and approvals

    /// Stores a new plan version. Only allowed while investigating, so a plan can never be
    /// swapped underneath a pending or granted approval.
    public func saveDecisionDocument(ticketID: String, markdown: String) async throws -> DecisionDocument {
        try await writer.write { db in
            try Self.insertDocument(db, ticketID: ticketID, markdown: markdown, investigation: nil)
        }
    }

    public func latestDecisionDocument(ticketID: String) async throws -> DecisionDocument? {
        try await writer.read { db in try Self.fetchLatestDocument(db, ticketID: ticketID) }
    }

    /// Records the user's decision on the exact plan they reviewed (`planHash`) and moves the
    /// ticket to the matching state, atomically.
    public func recordApproval(
        ticketID: String,
        decision: ApprovalDecision,
        planHash: String,
        notes: String
    ) async throws -> Approval {
        try await writer.write { db in
            guard let state = try Self.fetchState(db, ticketID: ticketID) else { throw WorkflowError.unknownTicket(ticketID) }
            guard state == .awaitingPlanApproval else {
                throw WorkflowError.illegalTransition(from: state, to: decision.resultingState)
            }
            guard let document = try Self.fetchLatestDocument(db, ticketID: ticketID),
                  document.contentHash == planHash else {
                throw WorkflowError.planHashMismatch
            }
            let approval = Approval(ticketID: ticketID, planHash: planHash, decision: decision, notes: notes, decidedAt: Date())
            try db.execute(
                sql: "INSERT INTO approval (ticketID, planHash, decision, notes, decidedAt, attempt) VALUES (?, ?, ?, ?, ?, \(Self.currentAttempt))",
                arguments: [ticketID, planHash, decision.rawValue, notes, approval.decidedAt.timeIntervalSince1970, ticketID]
            )
            try Self.applyTransition(
                db, ticketID: ticketID, to: decision.resultingState, kind: .approval,
                message: "Plan v\(document.version) \(decision.rawValue.replacingOccurrences(of: "_", with: " "))"
                    + (notes.isEmpty ? "" : ": \(notes)")
            )
            return approval
        }
    }

    public func latestApproval(ticketID: String) async throws -> Approval? {
        try await writer.read { db in try Self.fetchLatestApproval(db, ticketID: ticketID) }
    }

    /// Reads state, plan and approval in one snapshot so the verdict is consistent.
    public func implementationGate(ticketID: String) async throws -> ImplementationGate.Verdict {
        try await writer.read { db in
            guard let state = try Self.fetchState(db, ticketID: ticketID) else { throw WorkflowError.unknownTicket(ticketID) }
            return ImplementationGate.evaluate(
                state: state,
                latestDocument: try Self.fetchLatestDocument(db, ticketID: ticketID),
                latestApproval: try Self.fetchLatestApproval(db, ticketID: ticketID)
            )
        }
    }

    // MARK: - Workspaces and agent runs

    public func ticket(id: String) async throws -> Ticket? {
        try await writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM ticket WHERE id = ?", arguments: [id]).map(Self.ticket(from:))
        }
    }

    public func workspace(ticketID: String) async throws -> TicketWorkspace? {
        try await writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM ticketWorkspace WHERE ticketID = ?", arguments: [ticketID]).map { row in
                TicketWorkspace(
                    ticketID: row["ticketID"], repositoryID: row["repositoryID"], repositoryName: row["repositoryName"],
                    repositoryPath: row["repositoryPath"], baseBranch: row["baseBranch"], baseCommit: row["baseCommit"],
                    branch: row["branch"], worktreePath: row["worktreePath"],
                    createdAt: Date(timeIntervalSince1970: row["createdAt"])
                )
            }
        }
    }

    public func saveWorkspace(_ workspace: TicketWorkspace) async throws {
        try await writer.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO ticketWorkspace
                        (ticketID, repositoryID, repositoryName, repositoryPath, baseBranch, baseCommit, branch, worktreePath, createdAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    workspace.ticketID, workspace.repositoryID, workspace.repositoryName, workspace.repositoryPath,
                    workspace.baseBranch, workspace.baseCommit, workspace.branch, workspace.worktreePath,
                    workspace.createdAt.timeIntervalSince1970,
                ]
            )
        }
    }

    /// Moves the ticket into `state` and opens a run record in one transaction. The state machine
    /// makes this the single-flight guard: a second start fails because the ticket is already running.
    public func beginRun(
        _ kind: AgentRun.Kind,
        ticketID: String,
        entering state: WorkflowState,
        logPath: String,
        message: String
    ) async throws -> Int64 {
        try await writer.write { db in
            try Self.applyTransition(db, ticketID: ticketID, to: state, kind: .transition, message: message)
            try db.execute(
                sql: "INSERT INTO agentRun (ticketID, kind, startedAt, logPath, attempt) VALUES (?, ?, ?, ?, \(Self.currentAttempt))",
                arguments: [ticketID, kind.rawValue, Date().timeIntervalSince1970, logPath, ticketID]
            )
            return db.lastInsertedRowID
        }
    }

    /// Stores the new plan version, closes the run, and moves the ticket to `needs_clarification`
    /// or `awaiting_plan_approval`, atomically.
    public func completeInvestigation(
        runID: Int64,
        ticketID: String,
        markdown: String,
        investigation: Investigation,
        stats: AgentRunStats
    ) async throws -> DecisionDocument {
        try await writer.write { db in
            let document = try Self.insertDocument(db, ticketID: ticketID, markdown: markdown, investigation: investigation)
            try Self.closeRun(db, runID: runID, outcome: .succeeded, stats: stats, message: nil)
            if investigation.needsClarification {
                let count = investigation.clarifyingQuestions.count
                try Self.applyTransition(
                    db, ticketID: ticketID, to: .needsClarification, kind: .transition,
                    message: "Plan v\(document.version) needs clarification (\(count) question\(count == 1 ? "" : "s"))"
                )
            } else {
                try Self.applyTransition(db, ticketID: ticketID, to: .planReady, kind: .transition, message: "Plan v\(document.version) ready")
                try Self.applyTransition(db, ticketID: ticketID, to: .awaitingPlanApproval, kind: .transition, message: "Waiting for approval")
            }
            return document
        }
    }

    /// Closes a run that did not succeed and moves a still-running ticket to `cancelled` or `failed`.
    /// `result` keeps the agent's report when it stopped on its own (e.g. blocked).
    public func finishRun(
        runID: Int64,
        ticketID: String,
        outcome: AgentRun.Outcome,
        message: String,
        result: ImplementationResult? = nil
    ) async throws {
        try await writer.write { db in
            try Self.closeRun(db, runID: runID, outcome: outcome, stats: nil, message: message)
            if let result {
                try db.execute(sql: "UPDATE agentRun SET reportJSON = ? WHERE id = ?", arguments: [try Self.json(result), runID])
            }
            guard try Self.fetchState(db, ticketID: ticketID)?.isAgentRunning == true else { return }
            try Self.applyTransition(
                db, ticketID: ticketID, to: outcome == .cancelled ? .cancelled : .failed, kind: .transition, message: message
            )
        }
    }

    public func runs(ticketID: String) async throws -> [AgentRun] {
        try await writer.read { db in
            try Row.fetchAll(
                db, sql: "SELECT * FROM agentRun WHERE ticketID = ? AND attempt = \(Self.currentAttempt) ORDER BY id",
                arguments: [ticketID, ticketID]
            ).map { row in
                AgentRun(
                    id: row["id"], ticketID: row["ticketID"], kind: AgentRun.Kind(rawValue: row["kind"]) ?? .investigation,
                    startedAt: Date(timeIntervalSince1970: row["startedAt"]),
                    finishedAt: (row["finishedAt"] as Double?).map(Date.init(timeIntervalSince1970:)),
                    outcome: (row["outcome"] as String?).flatMap(AgentRun.Outcome.init(rawValue:)),
                    numTurns: row["numTurns"], costUSD: row["costUSD"], logPath: row["logPath"], errorMessage: row["errorMessage"],
                    implementation: Self.decodeReport(row, kind: .implementation),
                    validation: Self.decodeReport(row, kind: .validation),
                    review: Self.decodeReport(row, kind: .review)
                )
            }
        }
    }

    /// Re-checks the approval gate and claims the ticket for implementation in one transaction,
    /// so nothing can change the plan or approval between the check and the start.
    public func beginImplementation(ticketID: String, logPath: String) async throws -> (runID: Int64, plan: DecisionDocument) {
        try await writer.write { db in
            guard let state = try Self.fetchState(db, ticketID: ticketID) else { throw WorkflowError.unknownTicket(ticketID) }
            let plan = try Self.fetchLatestDocument(db, ticketID: ticketID)
            let verdict = ImplementationGate.evaluate(
                state: state, latestDocument: plan, latestApproval: try Self.fetchLatestApproval(db, ticketID: ticketID)
            )
            guard case .allowed = verdict, let plan else {
                if case .blocked(let reason) = verdict { throw WorkflowError.implementationBlocked(reason) }
                throw WorkflowError.implementationBlocked(.missingPlan)
            }
            try Self.applyTransition(
                db, ticketID: ticketID, to: .implementing, kind: .transition,
                message: "Implementation of plan v\(plan.version) started"
            )
            try db.execute(
                sql: "INSERT INTO agentRun (ticketID, kind, startedAt, logPath, attempt) VALUES (?, ?, ?, ?, \(Self.currentAttempt))",
                arguments: [ticketID, AgentRun.Kind.implementation.rawValue, Date().timeIntervalSince1970, logPath, ticketID]
            )
            return (db.lastInsertedRowID, plan)
        }
    }

    /// After a failed or stopped implementation, goes back to `approved` so it can be retried,
    /// but only if the latest plan's approval is still valid.
    public func returnToApprovedPlan(ticketID: String) async throws {
        try await writer.write { db in
            guard let state = try Self.fetchState(db, ticketID: ticketID) else { throw WorkflowError.unknownTicket(ticketID) }
            guard state == .failed || state == .cancelled else { throw WorkflowError.illegalTransition(from: state, to: .approved) }
            let plan = try Self.fetchLatestDocument(db, ticketID: ticketID)
            let verdict = ImplementationGate.evaluate(
                state: .approved, latestDocument: plan, latestApproval: try Self.fetchLatestApproval(db, ticketID: ticketID)
            )
            if case .blocked(let reason) = verdict { throw WorkflowError.implementationBlocked(reason) }
            try Self.applyTransition(
                db, ticketID: ticketID, to: .approved, kind: .transition,
                message: "Back to approved plan v\(plan?.version ?? 0) to retry implementation"
            )
        }
    }

    /// Closes a successful implementation run and moves the ticket on to `validating`.
    public func completeImplementation(
        runID: Int64,
        ticketID: String,
        result: ImplementationResult,
        stats: AgentRunStats
    ) async throws {
        try await writer.write { db in
            try Self.closeRun(db, runID: runID, outcome: .succeeded, stats: stats, message: nil)
            try db.execute(sql: "UPDATE agentRun SET reportJSON = ? WHERE id = ?", arguments: [try Self.json(result), runID])
            let count = result.changedFiles.count
            try Self.applyTransition(
                db, ticketID: ticketID, to: .validating, kind: .transition,
                message: "Implementation \(result.report.outcome.rawValue): \(count) file\(count == 1 ? "" : "s") changed"
            )
        }
    }

    /// Forgets a ticket's worktree after it was removed, so the next investigation creates a new
    /// one from the repository's current base branch. Not allowed while a run is active.
    public func deleteWorkspace(ticketID: String) async throws {
        try await writer.write { db in
            if let state = try Self.fetchState(db, ticketID: ticketID), state.isAgentRunning {
                throw WorkflowError.illegalTransition(from: state, to: state)
            }
            try db.execute(sql: "DELETE FROM ticketWorkspace WHERE ticketID = ?", arguments: [ticketID])
        }
    }

    /// Remembers the OS process group of a running agent so it can be stopped after a crash.
    public func recordProcessGroup(runID: Int64, processGroup: Int32) async throws {
        try await writer.write { db in
            try db.execute(sql: "UPDATE agentRun SET processGroup = ? WHERE id = ?", arguments: [processGroup, runID])
        }
    }

    /// Process groups of runs that never finished, i.e. the app stopped while they ran.
    public func unfinishedProcessGroups() async throws -> [Int32] {
        try await writer.read { db in
            try Int32.fetchAll(db, sql: "SELECT processGroup FROM agentRun WHERE finishedAt IS NULL AND processGroup IS NOT NULL")
        }
    }

    // MARK: - Validation, review and hand-off

    /// Opens a validation or review run. The ticket must already be resting in `state`
    /// (`validating` or `reviewing`); a second run for the same ticket is refused.
    public func beginVerificationRun(_ kind: AgentRun.Kind, ticketID: String, in state: WorkflowState, logPath: String) async throws -> Int64 {
        try await writer.write { db in
            guard let current = try Self.fetchState(db, ticketID: ticketID) else { throw WorkflowError.unknownTicket(ticketID) }
            guard current == state else { throw WorkflowError.illegalTransition(from: current, to: state) }
            let open = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agentRun WHERE ticketID = ? AND finishedAt IS NULL", arguments: [ticketID]) ?? 0
            guard open == 0 else { throw WorkflowError.illegalTransition(from: current, to: state) }
            try db.execute(
                sql: "INSERT INTO agentRun (ticketID, kind, startedAt, logPath, attempt) VALUES (?, ?, ?, ?, \(Self.currentAttempt))",
                arguments: [ticketID, kind.rawValue, Date().timeIntervalSince1970, logPath, ticketID]
            )
            return db.lastInsertedRowID
        }
    }

    /// Records validation results. With `thenReview`, moves `validating` → `reviewing`.
    public func completeValidation(runID: Int64, ticketID: String, result: ValidationResult, thenReview: Bool) async throws {
        try await writer.write { db in
            try Self.closeRun(db, runID: runID, outcome: .succeeded, stats: nil, message: nil)
            try db.execute(sql: "UPDATE agentRun SET reportJSON = ? WHERE id = ?", arguments: [try Self.json(result), runID])
            let failed = result.failed.count
            let summary = result.commands.isEmpty ? "No validation commands configured"
                : failed == 0 ? "All \(result.commands.count) validation command\(result.commands.count == 1 ? "" : "s") passed"
                : "\(failed) of \(result.commands.count) validation command\(result.commands.count == 1 ? "" : "s") failed"
            try Self.insertEvent(db, ticketID: ticketID, kind: .transition, from: nil, to: nil, message: summary, at: Date())
            if thenReview {
                try Self.applyTransition(db, ticketID: ticketID, to: .reviewing, kind: .transition, message: "Independent review started")
            }
        }
    }

    /// Records the review and hands the ticket to the user.
    public func completeReview(runID: Int64, ticketID: String, report: ReviewReport, stats: AgentRunStats) async throws {
        try await writer.write { db in
            try Self.closeRun(db, runID: runID, outcome: .succeeded, stats: stats, message: nil)
            try db.execute(sql: "UPDATE agentRun SET reportJSON = ? WHERE id = ?", arguments: [try Self.json(report), runID])
            let verdict = report.verdict == .approve ? "approved" : "requested changes"
            try Self.applyTransition(
                db, ticketID: ticketID, to: .readyForHumanReview, kind: .transition,
                message: "Review \(verdict) with \(report.findings.count) finding\(report.findings.count == 1 ? "" : "s"). Ready for your review"
            )
        }
    }

    /// Starts a fix of the existing implementation (failing validation, or the user's request
    /// from the hand-off). The approval of the latest plan must still be valid.
    public func beginFix(ticketID: String, logPath: String, reason: String) async throws -> (runID: Int64, plan: DecisionDocument) {
        try await writer.write { db in
            guard let state = try Self.fetchState(db, ticketID: ticketID) else { throw WorkflowError.unknownTicket(ticketID) }
            guard [.validating, .reviewing, .readyForHumanReview].contains(state) else {
                throw WorkflowError.implementationBlocked(.wrongState(state))
            }
            let plan = try Self.fetchLatestDocument(db, ticketID: ticketID)
            let verdict = ImplementationGate.evaluate(
                state: .approved, latestDocument: plan, latestApproval: try Self.fetchLatestApproval(db, ticketID: ticketID)
            )
            guard case .allowed = verdict, let plan else {
                if case .blocked(let reason) = verdict { throw WorkflowError.implementationBlocked(reason) }
                throw WorkflowError.implementationBlocked(.missingPlan)
            }
            try Self.applyTransition(db, ticketID: ticketID, to: .implementing, kind: .transition, message: reason)
            try db.execute(
                sql: "INSERT INTO agentRun (ticketID, kind, startedAt, logPath, attempt) VALUES (?, ?, ?, ?, \(Self.currentAttempt))",
                arguments: [ticketID, AgentRun.Kind.implementation.rawValue, Date().timeIntervalSince1970, logPath, ticketID]
            )
            return (db.lastInsertedRowID, plan)
        }
    }

    /// Back to `selected` from any resting state with a clean slate: the worktree record is
    /// forgotten and a new attempt begins, so earlier plans, approvals, runs and history are no
    /// longer shown or given to the next investigation. They stay in the database as an audit
    /// trail. Not allowed while anything runs or once the ticket is done.
    public func startOver(ticketID: String) async throws {
        try await writer.write { db in
            guard let state = try Self.fetchState(db, ticketID: ticketID) else { throw WorkflowError.unknownTicket(ticketID) }
            let openRuns = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agentRun WHERE ticketID = ? AND finishedAt IS NULL", arguments: [ticketID]) ?? 0
            guard !state.isAgentRunning, openRuns == 0, state != .completeManual, state != .discovered else {
                throw WorkflowError.illegalTransition(from: state, to: .selected)
            }
            try db.execute(sql: "DELETE FROM ticketWorkspace WHERE ticketID = ?", arguments: [ticketID])
            // The way back is recorded in the attempt being closed.
            if state != .selected {
                if !state.canTransition(to: .selected) {
                    try Self.applyTransition(db, ticketID: ticketID, to: .cancelled, kind: .transition, message: "Started over by user")
                }
                try Self.applyTransition(db, ticketID: ticketID, to: .selected, kind: .transition, message: "Started over by user")
            }
            try db.execute(sql: "UPDATE ticketWorkflow SET attempt = attempt + 1 WHERE ticketID = ?", arguments: [ticketID])
            let attempt = try Int.fetchOne(db, sql: "SELECT attempt FROM ticketWorkflow WHERE ticketID = ?", arguments: [ticketID]) ?? 0
            try Self.insertEvent(
                db, ticketID: ticketID, kind: .transition, from: nil, to: .selected,
                message: "Started over (attempt \(attempt)): fresh worktree, no earlier plans or answers", at: Date()
            )
        }
    }

    /// The user has reviewed and committed the work.
    public func markDone(ticketID: String) async throws {
        try await writer.write { db in
            try Self.applyTransition(db, ticketID: ticketID, to: .completeManual, kind: .transition, message: "Marked done by user")
        }
    }

    /// Records the user's answers to clarifying questions for the next investigation.
    public func recordClarification(ticketID: String, answers: String) async throws {
        try await writer.write { db in
            guard let state = try Self.fetchState(db, ticketID: ticketID) else { throw WorkflowError.unknownTicket(ticketID) }
            guard state == .needsClarification else { throw WorkflowError.illegalTransition(from: state, to: .investigating) }
            try Self.insertEvent(db, ticketID: ticketID, kind: .clarification, from: nil, to: nil, message: answers, at: Date())
        }
    }

    /// Clarification answers and revision notes, oldest first, to feed into the next investigation.
    public func guidance(ticketID: String) async throws -> [String] {
        try await writer.read { db in
            try String.fetchAll(db, sql: """
                SELECT text FROM (
                    SELECT 'Answers to clarifying questions: ' || message AS text, createdAt AS at
                    FROM workflowEvent WHERE ticketID = ? AND kind = 'clarification' AND attempt = \(Self.currentAttempt)
                    UNION ALL
                    SELECT 'Revision requested: ' || notes AS text, decidedAt AS at
                    FROM approval WHERE ticketID = ? AND decision = ? AND notes != '' AND attempt = \(Self.currentAttempt)
                ) ORDER BY at
                """, arguments: [ticketID, ticketID, ticketID, ApprovalDecision.revisionRequested.rawValue, ticketID])
        }
    }

    // MARK: - Helpers (run inside a transaction)

    /// New plan versions are only accepted while investigating, so a plan can never be swapped
    /// underneath a pending or granted approval.
    private static func insertDocument(
        _ db: Database,
        ticketID: String,
        markdown: String,
        investigation: Investigation?
    ) throws -> DecisionDocument {
        guard let state = try fetchState(db, ticketID: ticketID) else { throw WorkflowError.unknownTicket(ticketID) }
        guard state == .investigating else { throw WorkflowError.decisionDocumentNotAllowed(in: state) }
        let version = (try Int.fetchOne(
            db, sql: "SELECT MAX(version) FROM decisionDocument WHERE ticketID = ? AND attempt = \(currentAttempt)",
            arguments: [ticketID, ticketID]
        ) ?? 0) + 1
        let document = DecisionDocument(
            ticketID: ticketID, version: version, markdown: markdown, createdAt: Date(), investigation: investigation
        )
        try db.execute(
            sql: """
                INSERT INTO decisionDocument (ticketID, version, markdown, contentHash, createdAt, investigationJSON, attempt)
                VALUES (?, ?, ?, ?, ?, ?, \(currentAttempt))
                """,
            arguments: [
                ticketID, version, markdown, document.contentHash, document.createdAt.timeIntervalSince1970,
                try investigation.map(json), ticketID,
            ]
        )
        return document
    }

    private static func decodeReport<T: Decodable>(_ row: Row, kind: AgentRun.Kind) -> T? {
        guard (row["kind"] as String?) == kind.rawValue, let json = row["reportJSON"] as String? else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private static func closeRun(_ db: Database, runID: Int64, outcome: AgentRun.Outcome, stats: AgentRunStats?, message: String?) throws {
        try db.execute(
            sql: """
                UPDATE agentRun SET finishedAt = ?, outcome = ?, numTurns = ?, costUSD = ?, errorMessage = ?
                WHERE id = ? AND finishedAt IS NULL
                """,
            arguments: [Date().timeIntervalSince1970, outcome.rawValue, stats?.numTurns, stats?.costUSD, message, runID]
        )
    }

    private static func applyTransition(
        _ db: Database,
        ticketID: String,
        to next: WorkflowState,
        kind: WorkflowEvent.Kind,
        message: String
    ) throws {
        guard let current = try fetchState(db, ticketID: ticketID) else { throw WorkflowError.unknownTicket(ticketID) }
        guard current.canTransition(to: next) else { throw WorkflowError.illegalTransition(from: current, to: next) }
        let now = Date()
        try db.execute(
            sql: "UPDATE ticketWorkflow SET state = ?, updatedAt = ? WHERE ticketID = ?",
            arguments: [next.rawValue, now.timeIntervalSince1970, ticketID]
        )
        try insertEvent(db, ticketID: ticketID, kind: kind, from: current, to: next, message: message, at: now)
    }

    private static func insertEvent(
        _ db: Database,
        ticketID: String,
        kind: WorkflowEvent.Kind,
        from: WorkflowState?,
        to: WorkflowState?,
        message: String,
        at date: Date
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO workflowEvent (ticketID, kind, fromState, toState, message, createdAt, attempt)
                VALUES (?, ?, ?, ?, ?, ?, \(currentAttempt))
                """,
            arguments: [ticketID, kind.rawValue, from?.rawValue, to?.rawValue, message, date.timeIntervalSince1970, ticketID]
        )
    }

    private static func fetchState(_ db: Database, ticketID: String) throws -> WorkflowState? {
        try String.fetchOne(db, sql: "SELECT state FROM ticketWorkflow WHERE ticketID = ?", arguments: [ticketID])
            .flatMap(WorkflowState.init(rawValue:))
    }

    private static func fetchLatestDocument(_ db: Database, ticketID: String) throws -> DecisionDocument? {
        try Row.fetchOne(
            db, sql: "SELECT * FROM decisionDocument WHERE ticketID = ? AND attempt = \(currentAttempt) ORDER BY version DESC LIMIT 1",
            arguments: [ticketID, ticketID]
        ).map { row in
            DecisionDocument(
                ticketID: row["ticketID"], version: row["version"], markdown: row["markdown"],
                createdAt: Date(timeIntervalSince1970: row["createdAt"]),
                investigation: (row["investigationJSON"] as String?).flatMap {
                    try? JSONDecoder().decode(Investigation.self, from: Data($0.utf8))
                }
            )
        }
    }

    private static func fetchLatestApproval(_ db: Database, ticketID: String) throws -> Approval? {
        try Row.fetchOne(
            db, sql: "SELECT * FROM approval WHERE ticketID = ? AND attempt = \(currentAttempt) ORDER BY id DESC LIMIT 1",
            arguments: [ticketID, ticketID]
        ).map { row in
            Approval(
                ticketID: row["ticketID"], planHash: row["planHash"],
                decision: ApprovalDecision(rawValue: row["decision"]) ?? .rejected,
                notes: row["notes"], decidedAt: Date(timeIntervalSince1970: row["decidedAt"])
            )
        }
    }

    private static func ticket(from row: Row) throws -> Ticket {
        let decoder = JSONDecoder()
        let providerRaw: String = row["provider"]
        guard let provider = TicketProviderKind(rawValue: providerRaw) else {
            throw TicketProviderError.invalidResponse("Unknown provider '\(providerRaw)' in database")
        }
        let urlString: String = row["url"]
        guard let url = URL(string: urlString) else {
            throw TicketProviderError.invalidResponse("Invalid ticket URL '\(urlString)' in database")
        }
        return Ticket(
            provider: provider,
            source: row["source"],
            externalID: row["externalID"],
            title: row["title"],
            description: row["description"],
            status: row["status"],
            assignee: row["assignee"],
            url: url,
            comments: try decoder.decode([TicketComment].self, from: Data((row["commentsJSON"] as String).utf8)),
            acceptanceCriteria: try decoder.decode([String].self, from: Data((row["acceptanceCriteriaJSON"] as String).utf8)),
            fetchedAt: Date(timeIntervalSince1970: row["fetchedAt"]),
            type: TicketType(rawValue: row["type"]) ?? .feature
        )
    }

    private static func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
}
