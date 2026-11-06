import Foundation
import Testing
@testable import DevPilotCore

/// After the user rebases a ticket's branch onto a newer base branch, only the ticket's own
/// changes count as changed (for validation, review, QA and the Changes window).
struct CurrentBaseTests {
    func commit(_ repo: TestRepository, _ file: String, in directory: URL, message: String) async throws {
        let url = directory.appending(path: file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "\(message)\n".write(to: url, atomically: true, encoding: .utf8)
        try await repo.git("add", "-A", in: directory)
        try await repo.git("-c", "user.email=test@example.com", "-c", "user.name=Test", "commit", "-q", "-m", message, in: directory)
    }

    @Test func rebasedOntoANewerOriginBranchWhileLocalMainIsStale() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        let workspace = try await repo.manager.prepareWorktree(for: .sample(), repository: repo.config)
        let worktree = URL(filePath: workspace.worktreePath)
        try await commit(repo, "app/models/customer.rb", in: worktree, message: "ticket")

        // Other people's work lands on origin/main; local main stays where it was.
        try await repo.git("checkout", "-q", "-b", "upstream")
        try await commit(repo, "frontend/src/app.ts", in: repo.repo, message: "someone else")
        try await repo.git("update-ref", "refs/remotes/origin/main", "upstream")
        try await repo.git("checkout", "-q", "main")
        try await repo.git("-c", "user.email=test@example.com", "-c", "user.name=Test", "rebase", "-q", "origin/main", in: worktree)

        let before = try await repo.manager.changedFiles(in: workspace.worktreePath, since: workspace.baseCommit).map(\.path)
        #expect(Set(before) == ["app/models/customer.rb", "frontend/src/app.ts"])
        let current = await repo.manager.withCurrentBase(workspace)
        #expect(current.baseCommit == (try await repo.git("rev-parse", "origin/main")))
        #expect(try await repo.manager.changedFiles(in: current.worktreePath, since: current.baseCommit).map(\.path) == ["app/models/customer.rb"])
        #expect(await repo.manager.branchStatus(workspace)?.commitsSinceBase == 1)
    }

    @Test func mergingTheBaseBranchInMovesTheBaseToo() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        let workspace = try await repo.manager.prepareWorktree(for: .sample(), repository: repo.config)
        let worktree = URL(filePath: workspace.worktreePath)
        try await commit(repo, "ticket.txt", in: worktree, message: "ticket")
        try await commit(repo, "other.txt", in: repo.repo, message: "main moved on")
        try await repo.git("-c", "user.email=test@example.com", "-c", "user.name=Test", "merge", "-q", "--no-edit", "main", in: worktree)

        let current = await repo.manager.withCurrentBase(workspace)
        #expect(try await repo.manager.changedFiles(in: current.worktreePath, since: current.baseCommit).map(\.path) == ["ticket.txt"])
    }

    @Test func untouchedBranchKeepsTheRecordedBase() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        let workspace = try await repo.manager.prepareWorktree(for: .sample(), repository: repo.config)
        // main moving on without the branch taking it in changes nothing.
        try await commit(repo, "other.txt", in: repo.repo, message: "main moved on")
        #expect(await repo.manager.withCurrentBase(workspace) == workspace)
    }

    @Test func validationEnvironmentLines() {
        let text = "# like CI\nRAILS_LOG_LEVEL=error\n\n  TOKEN = a=b \nnot a variable\n=x"
        #expect(CommandPresets.environment(fromLines: text) == ["RAILS_LOG_LEVEL": "error", "TOKEN": " a=b"])
        #expect(CommandPresets.validationEnvironment(for: [CommandRule(command: CommandPresets.changedSpecsCommand)]) == "RAILS_LOG_LEVEL=error")
        #expect(CommandPresets.validationEnvironment(for: [CommandRule(command: "pnpm test")]).isEmpty)
    }
}
