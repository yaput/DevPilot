import Foundation

/// App-owned files (decision records, agent transcripts), kept outside every worktree.
public struct ArtifactStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func directory(for ticketID: String) -> URL {
        let safe = String(ticketID.map { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) ? $0 : "_" })
        return root.appending(path: safe, directoryHint: .isDirectory)
    }

    public func runLogURL(ticketID: String, kind: AgentRun.Kind, at date: Date) -> URL {
        let stamp = date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).dateTimeSeparator(.standard))
            .replacingOccurrences(of: ":", with: "")
        return directory(for: ticketID).appending(path: "\(kind.rawValue)-\(stamp).jsonl")
    }

    public func decisionURL(for document: DecisionDocument) -> URL {
        directory(for: document.ticketID).appending(path: "decision-v\(document.version).md")
    }

    @discardableResult
    public func write(_ document: DecisionDocument) throws -> URL {
        let url = decisionURL(for: document)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try document.markdown.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

public enum InvestigationEvent: Sendable {
    /// The ticket is now `investigating`.
    case started
    case progress(String)
}

/// Runs a read-only investigation for one ticket and records the outcome.
public final class InvestigationService: Sendable {
    private let database: AppDatabase
    private let worktrees: GitWorktreeManager
    private let runner: any AgentRunner
    private let artifacts: ArtifactStore

    public init(database: AppDatabase, worktrees: GitWorktreeManager, runner: any AgentRunner, artifacts: ArtifactStore) {
        self.database = database
        self.worktrees = worktrees
        self.runner = runner
        self.artifacts = artifacts
    }

    /// Starts from `selected`, `needs_clarification` or `needs_revision`. The repository is only
    /// used when the ticket has no worktree yet; afterwards the ticket stays on its worktree.
    public func investigate(
        ticketID: String,
        repository: RepositoryConfig,
        onEvent: @escaping @Sendable (InvestigationEvent) -> Void
    ) async throws -> DecisionDocument {
        guard let ticket = try await database.ticket(id: ticketID) else { throw WorkflowError.unknownTicket(ticketID) }
        let logURL = artifacts.runLogURL(ticketID: ticketID, kind: .investigation, at: Date())
        let runID = try await database.beginRun(
            .investigation, ticketID: ticketID, entering: .investigating, logPath: logURL.path,
            message: "Investigation started"
        )
        onEvent(.started)

        do {
            onEvent(.progress("Preparing worktree"))
            let workspace = try await workspace(for: ticket, repository: repository)
            let request = InvestigationRequest(
                ticket: ticket,
                workspace: workspace,
                previousPlan: try await database.latestDecisionDocument(ticketID: ticketID),
                guidance: try await database.guidance(ticketID: ticketID),
                logURL: logURL
            )
            let (investigation, stats) = try await runner.investigate(request) { onEvent(.progress($0)) }
            let markdown = DecisionDocumentRenderer.render(investigation, ticket: ticket, workspace: workspace)
            let document = try await database.completeInvestigation(
                runID: runID, ticketID: ticketID, markdown: markdown, investigation: investigation, stats: stats
            )
            // The database is the source of truth; the file is a convenience copy.
            try? artifacts.write(document)
            return document
        } catch {
            let outcome: AgentRun.Outcome = switch error {
            case is CancellationError: .cancelled
            case AgentError.timedOut: .timedOut
            default: .failed
            }
            let message = outcome == .cancelled ? "Stopped by user" : error.localizedDescription
            // Recorded from a fresh task: the current one may be cancelled, and the ticket must
            // never be left looking like it is still running.
            await Task {
                try? await database.finishRun(runID: runID, ticketID: ticketID, outcome: outcome, message: message)
            }.value
            throw error
        }
    }

    private func workspace(for ticket: Ticket, repository: RepositoryConfig) async throws -> TicketWorkspace {
        if let existing = try await database.workspace(ticketID: ticket.id),
           FileManager.default.fileExists(atPath: existing.worktreePath) {
            return existing
        }
        let workspace = try await worktrees.prepareWorktree(for: ticket, repository: repository)
        try await database.saveWorkspace(workspace)
        return workspace
    }
}
