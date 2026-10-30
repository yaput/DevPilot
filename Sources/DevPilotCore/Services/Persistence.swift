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
                    externalID TEXT NOT NULL,
                    title TEXT NOT NULL,
                    description TEXT NOT NULL,
                    status TEXT NOT NULL,
                    assignee TEXT,
                    url TEXT NOT NULL,
                    commentsJSON TEXT NOT NULL,
                    acceptanceCriteriaJSON TEXT NOT NULL,
                    fetchedAt REAL NOT NULL,
                    UNIQUE (provider, externalID)
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
        return migrator
    }

    // MARK: - Tickets

    /// Inserts or refreshes tickets. Newly seen tickets start in `discovered`; existing
    /// tickets keep their workflow state.
    public func upsertTickets(_ tickets: [Ticket]) async throws {
        try await writer.write { db in
            for ticket in tickets {
                try db.execute(
                    sql: """
                        INSERT INTO ticket (id, provider, externalID, title, description, status, assignee, url,
                                            commentsJSON, acceptanceCriteriaJSON, fetchedAt)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                            title = excluded.title, description = excluded.description, status = excluded.status,
                            assignee = excluded.assignee, url = excluded.url, commentsJSON = excluded.commentsJSON,
                            acceptanceCriteriaJSON = excluded.acceptanceCriteriaJSON, fetchedAt = excluded.fetchedAt
                        """,
                    arguments: [
                        ticket.id, ticket.provider.rawValue, ticket.externalID, ticket.title, ticket.description,
                        ticket.status, ticket.assignee, ticket.url.absoluteString,
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
        }
    }

    public func tickets() async throws -> [Ticket] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM ticket ORDER BY provider, externalID").map(Self.ticket(from:))
        }
    }

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
            guard let state = try Self.fetchState(db, ticketID: ticketID) else { throw WorkflowError.unknownTicket(ticketID) }
            guard state == .investigating else { throw WorkflowError.decisionDocumentNotAllowed(in: state) }
            let version = (try Int.fetchOne(
                db, sql: "SELECT MAX(version) FROM decisionDocument WHERE ticketID = ?", arguments: [ticketID]
            ) ?? 0) + 1
            let document = DecisionDocument(ticketID: ticketID, version: version, markdown: markdown, createdAt: Date())
            try db.execute(
                sql: "INSERT INTO decisionDocument (ticketID, version, markdown, contentHash, createdAt) VALUES (?, ?, ?, ?, ?)",
                arguments: [ticketID, version, markdown, document.contentHash, document.createdAt.timeIntervalSince1970]
            )
            return document
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

    // MARK: - Helpers (run inside a transaction)

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
                createdAt: Date(timeIntervalSince1970: row["createdAt"])
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
