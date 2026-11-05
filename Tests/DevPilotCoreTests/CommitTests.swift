import Foundation
import Testing
@testable import DevPilotCore

struct CommitTests {
    let tools = ToolEnvironment(path: "", javaHome: "")

    /// A ticket worktree, with a git identity so commits work on any machine.
    func fixture() async throws -> (TestRepository, TicketWorkspace, URL) {
        let repo = try await TestRepository(files: ["README.md": "# Test\n", "old.txt": "old\n"])
        try await repo.git("config", "user.email", "test@example.com")
        try await repo.git("config", "user.name", "Test")
        let workspace = try await repo.manager.prepareWorktree(for: .sample(), repository: repo.config)
        return (repo, workspace, URL(filePath: workspace.worktreePath, directoryHint: .isDirectory))
    }

    @Test func commitsEverythingOnTheTicketBranchExceptExcludedFiles() async throws {
        let (repo, workspace, worktree) = try await fixture()
        defer { repo.remove() }
        try "# Changed\n".write(to: worktree.appending(path: "README.md"), atomically: true, encoding: .utf8)
        try "new\n".write(to: worktree.appending(path: "new.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: worktree.appending(path: "old.txt"))
        try "SECRET=1\n".write(to: worktree.appending(path: ".env"), atomically: true, encoding: .utf8)

        let hash = try await repo.manager.commitAll(workspace, message: "SC-1: Retry webhooks", excluding: [".env"], tools: tools)

        #expect(try await repo.git("log", "-1", "--format=%h %s", workspace.branch) == "\(hash) SC-1: Retry webhooks")
        #expect(try await repo.git("show", "--name-status", "--format=", workspace.branch)
            .split(separator: "\n").sorted() == ["A\tnew.txt", "D\told.txt", "M\tREADME.md"])
        // The excluded file stays untracked; main is untouched.
        #expect(try await repo.manager.changedFiles(in: workspace.worktreePath) == [ChangedFile(path: ".env", change: .untracked)])
        #expect(try await repo.git("log", "-1", "--format=%s", "main") == "init")

        // Committed work still counts as the ticket's changes.
        let changed = try await repo.manager.changedFiles(in: workspace.worktreePath, since: workspace.baseCommit)
        #expect(Set(changed) == [
            ChangedFile(path: "README.md", change: .modified), ChangedFile(path: "new.txt", change: .added),
            ChangedFile(path: "old.txt", change: .deleted), ChangedFile(path: ".env", change: .untracked),
        ])
        let status = try #require(await repo.manager.branchStatus(workspace))
        #expect(status.commitsSinceBase == 1 && status.uncommittedFiles == 1)
    }

    @Test func aFailingHookStopsTheCommitUnlessSkipped() async throws {
        let (repo, workspace, worktree) = try await fixture()
        defer { repo.remove() }
        let hook = repo.repo.appending(path: ".git/hooks/pre-commit")
        try "#!/bin/sh\necho 'lint: 2 problems' >&2\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try "x\n".write(to: worktree.appending(path: "x.txt"), atomically: true, encoding: .utf8)

        await #expect {
            try await repo.manager.commitAll(workspace, message: "m", tools: tools)
        } throws: { error in
            guard case CommitError.failed(let output) = error else { return false }
            return output.contains("lint: 2 problems")
        }
        #expect(try await repo.git("rev-list", "--count", "\(workspace.baseCommit)..\(workspace.branch)") == "0")

        _ = try await repo.manager.commitAll(workspace, message: "m", tools: tools, skippingHooks: true)
        #expect(try await repo.git("rev-list", "--count", "\(workspace.baseCommit)..\(workspace.branch)") == "1")
    }

    @Test func refusesWithNothingToCommitOrOnAnotherBranch() async throws {
        let (repo, workspace, worktree) = try await fixture()
        defer { repo.remove() }
        await #expect(throws: CommitError.nothingToCommit) {
            try await repo.manager.commitAll(workspace, message: "m", tools: tools)
        }
        await #expect(throws: CommitError.emptyMessage) {
            try await repo.manager.commitAll(workspace, message: "  \n", tools: tools)
        }
        try await repo.git("checkout", "-q", "-b", "elsewhere", in: worktree)
        try "x\n".write(to: worktree.appending(path: "x.txt"), atomically: true, encoding: .utf8)
        await #expect(throws: CommitError.wrongBranch(expected: workspace.branch, actual: "elsewhere")) {
            try await repo.manager.commitAll(workspace, message: "m", tools: tools)
        }
    }

    @Test func commitsAreTheUsersAloneEvenIfAHookAddsCoAuthors() async throws {
        let (repo, workspace, worktree) = try await fixture()
        defer { repo.remove() }
        let hook = repo.repo.appending(path: ".git/hooks/commit-msg")
        try "#!/bin/sh\nprintf '\\nCo-authored-by: Bot <bot@example.com>\\n' >> \"$1\"\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try "x\n".write(to: worktree.appending(path: "x.txt"), atomically: true, encoding: .utf8)

        let message = "SC-1: Fix\n\nBody line.\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\n🤖 Generated with [Claude Code](https://claude.com/claude-code)"
        _ = try await repo.manager.commitAll(workspace, message: message, tools: tools)

        #expect(try await repo.git("log", "-1", "--format=%B", workspace.branch) == "SC-1: Fix\n\nBody line.")
        #expect(try await repo.git("log", "-1", "--format=%an <%ae> | %cn <%ce>", workspace.branch)
            == "Test <test@example.com> | Test <test@example.com>")
    }

    @Test func parsesNameStatusWithRenames() {
        let output = "M\0a.swift\0R087\0old name.txt\0new name.txt\0A\0b.txt\0D\0c.txt\0"
        #expect(GitWorktreeManager.parseNameStatus(output) == [
            ChangedFile(path: "a.swift", change: .modified), ChangedFile(path: "new name.txt", change: .renamed),
            ChangedFile(path: "b.txt", change: .added), ChangedFile(path: "c.txt", change: .deleted),
        ])
    }

    @Test func hooksSeeTheUsersToolsButNoCIFlag() {
        let environment = GitWorktreeManager.commitEnvironment(tools: ToolEnvironment(path: "/opt/homebrew/bin", javaHome: "/jdk"))
        #expect(environment["PATH"]?.hasPrefix("/opt/homebrew/bin:") == true)
        #expect(environment["JAVA_HOME"] == "/jdk")
        #expect(environment["CI"] == nil && environment["GRADLE_OPTS"] == nil)
    }
}
