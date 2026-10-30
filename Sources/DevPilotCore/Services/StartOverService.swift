import Foundation

/// "Start Over": a clean slate for a ticket. Removes its worktree (uncommitted changes
/// included; the user confirmed), starts a new attempt so earlier plans, answers and runs are
/// neither shown nor used as context, and deletes the ticket's transcripts and artifacts.
/// Database records of earlier attempts are kept as the audit trail.
public struct StartOverService: Sendable {
    private let database: AppDatabase
    private let worktrees: GitWorktreeManager
    private let artifacts: ArtifactStore

    public init(database: AppDatabase, worktrees: GitWorktreeManager, artifacts: ArtifactStore) {
        self.database = database
        self.worktrees = worktrees
        self.artifacts = artifacts
    }

    /// Returns the branch name if it was kept because it has commits.
    @discardableResult
    public func startOver(ticketID: String) async throws -> String? {
        var keptBranch: String?
        if let workspace = try await database.workspace(ticketID: ticketID) {
            let deleted = try await worktrees.removeWorktree(workspace, discardingChanges: true)
            keptBranch = deleted ? nil : workspace.branch
        }
        try await database.startOver(ticketID: ticketID)
        // Files go last: if anything above failed, nothing has been lost yet.
        let directory = artifacts.directory(for: ticketID)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        return keptBranch
    }
}
