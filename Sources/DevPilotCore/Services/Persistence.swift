import Foundation
import GRDB

/// SQLite store for tickets, workflow state, decision documents, approvals and the audit trail.
/// Lives in Application Support, outside any agent-writable worktree.
///
/// Every state change goes through `applyTransition` inside a single write transaction,
/// together with its audit event, so a crash can never leave state and history out of sync.
public final class AppDatabase: Sendable {
    private let writer: any DatabaseWriter

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
        return migrator
    }

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
                                            commentsJSON, acceptanceCriteriaJSON, fetchedAt, isAssigned)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
                        ON CONFLICT(id) DO UPDATE SET
                            title = excluded.title, description = excluded.description, status = excluded.status,
                            assignee = excluded.assignee, url = excluded.url, commentsJSON = excluded.commentsJSON,
                            acceptanceCriteriaJSON = excluded.acceptanceCriteriaJSON, fetchedAt = excluded.fetchedAt,
                            isAssigned = 1
                        """,
                    arguments: [
                        ticket.id, ticket.provider.rawValue, ticket.source, ticket.externalID, ticket.title,
                        ticket.description, ticket.status, ticket.assignee, ticket.url.absoluteString,
                        try Self.json(ticket.comments), try Self.json(ticket.acceptanceCriteria),
                        ticket.fetchedAt.timeIntervalSince1970,
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
            let running = WorkflowState.allCases.filter(\.isAgentRunning).map(\.rawValue)
            let ids = try String.fetchAll(
                db,
                sql: "SELECT ticketID FROM ticketWorkflow WHERE state IN (\(running.map { _ in "?" }.joined(separator: ",")))",
                arguments: StatementArguments(running)
            )
            for id in ids {
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
            try Row.fetchAll(db, sql: "SELECT * FROM workflowEvent WHERE ticketID = ? ORDER BY id", arguments: [ticketID])
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
                sql: "INSERT INTO approval (ticketID, planHash, decision, notes, decidedAt) VALUES (?, ?, ?, ?, ?)",
                arguments: [ticketID, planHash, decision.rawValue, notes, approval.decidedAt.timeIntervalSince1970]
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
                sql: "INSERT INTO agentRun (ticketID, kind, startedAt, logPath) VALUES (?, ?, ?, ?)",
                arguments: [ticketID, kind.rawValue, Date().timeIntervalSince1970, logPath]
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
    public func finishRun(runID: Int64, ticketID: String, outcome: AgentRun.Outcome, message: String) async throws {
        try await writer.write { db in
            try Self.closeRun(db, runID: runID, outcome: outcome, stats: nil, message: message)
            guard try Self.fetchState(db, ticketID: ticketID)?.isAgentRunning == true else { return }
            try Self.applyTransition(
                db, ticketID: ticketID, to: outcome == .cancelled ? .cancelled : .failed, kind: .transition, message: message
            )
        }
    }

    public func runs(ticketID: String) async throws -> [AgentRun] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM agentRun WHERE ticketID = ? ORDER BY id", arguments: [ticketID]).map { row in
                AgentRun(
                    id: row["id"], ticketID: row["ticketID"], kind: AgentRun.Kind(rawValue: row["kind"]) ?? .investigation,
                    startedAt: Date(timeIntervalSince1970: row["startedAt"]),
                    finishedAt: (row["finishedAt"] as Double?).map(Date.init(timeIntervalSince1970:)),
                    outcome: (row["outcome"] as String?).flatMap(AgentRun.Outcome.init(rawValue:)),
                    numTurns: row["numTurns"], costUSD: row["costUSD"], logPath: row["logPath"], errorMessage: row["errorMessage"]
                )
            }
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
                    FROM workflowEvent WHERE ticketID = ? AND kind = 'clarification'
                    UNION ALL
                    SELECT 'Revision requested: ' || notes AS text, decidedAt AS at
                    FROM approval WHERE ticketID = ? AND decision = ? AND notes != ''
                ) ORDER BY at
                """, arguments: [ticketID, ticketID, ApprovalDecision.revisionRequested.rawValue])
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
            db, sql: "SELECT MAX(version) FROM decisionDocument WHERE ticketID = ?", arguments: [ticketID]
        ) ?? 0) + 1
        let document = DecisionDocument(
            ticketID: ticketID, version: version, markdown: markdown, createdAt: Date(), investigation: investigation
        )
        try db.execute(
            sql: """
                INSERT INTO decisionDocument (ticketID, version, markdown, contentHash, createdAt, investigationJSON)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                ticketID, version, markdown, document.contentHash, document.createdAt.timeIntervalSince1970,
                try investigation.map(json),
            ]
        )
        return document
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
            sql: "INSERT INTO workflowEvent (ticketID, kind, fromState, toState, message, createdAt) VALUES (?, ?, ?, ?, ?, ?)",
            arguments: [ticketID, kind.rawValue, from?.rawValue, to?.rawValue, message, date.timeIntervalSince1970]
        )
    }

    private static func fetchState(_ db: Database, ticketID: String) throws -> WorkflowState? {
        try String.fetchOne(db, sql: "SELECT state FROM ticketWorkflow WHERE ticketID = ?", arguments: [ticketID])
            .flatMap(WorkflowState.init(rawValue:))
    }

    private static func fetchLatestDocument(_ db: Database, ticketID: String) throws -> DecisionDocument? {
        try Row.fetchOne(
            db, sql: "SELECT * FROM decisionDocument WHERE ticketID = ? ORDER BY version DESC LIMIT 1", arguments: [ticketID]
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
            db, sql: "SELECT * FROM approval WHERE ticketID = ? ORDER BY id DESC LIMIT 1", arguments: [ticketID]
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
            fetchedAt: Date(timeIntervalSince1970: row["fetchedAt"])
        )
    }

    private static func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
}
