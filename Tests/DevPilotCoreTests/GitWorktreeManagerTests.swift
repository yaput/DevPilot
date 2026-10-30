import Foundation
import Testing
@testable import DevPilotCore

struct GitWorktreeManagerTests {
    func ticket(_ externalID: String, source: String = "acme.atlassian.net") -> Ticket {
        Ticket(
            provider: .jira, source: source, externalID: externalID, title: "T", description: "", status: "To Do",
            assignee: nil, url: URL(string: "https://example.com")!, comments: [], acceptanceCriteria: [], fetchedAt: Date()
        )
    }

    @Test func inspectFindsTopLevelAndCurrentBranch() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        let inspection = try await repo.manager.inspect(path: repo.repo.path)
        #expect(GitWorktreeManager.realPath(inspection.topLevel) == GitWorktreeManager.realPath(repo.repo.path))
        #expect(inspection.defaultBranch == "main")
    }

    @Test func inspectRejectsSubdirectoriesAndNonRepositories() async throws {
        let repo = try await TestRepository(files: ["src/app.swift": "let x = 1\n"])
        defer { repo.remove() }
        await #expect(throws: WorkspaceError.self) {
            _ = try await repo.manager.inspect(path: repo.repo.appending(path: "src").path)
        }
        await #expect(throws: WorkspaceError.notAGitRepository(repo.worktrees.deletingLastPathComponent().path)) {
            _ = try await repo.manager.inspect(path: repo.worktrees.deletingLastPathComponent().path)
        }
        await #expect(throws: WorkspaceError.repositoryMissing("/nonexistent/devpilot")) {
            _ = try await repo.manager.inspect(path: "/nonexistent/devpilot")
        }
    }

    @Test func createsIsolatedWorktreeOnNewBranch() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }

        let workspace = try await repo.manager.prepareWorktree(for: ticket("PLAT-182"), repository: repo.config)

        #expect(workspace.branch == "feat/PLAT-182")
        #expect(workspace.worktreePath == repo.worktrees.appending(path: "test-repo/jira-plat-182").path)
        #expect(FileManager.default.fileExists(atPath: URL(filePath: workspace.worktreePath).appending(path: "README.md").path))
        let head = try await repo.git("rev-parse", "HEAD")
        #expect(workspace.baseCommit == head)
        let branch = try await repo.git("branch", "--show-current", in: URL(filePath: workspace.worktreePath))
        #expect(branch == "feat/PLAT-182")
        // The main checkout is untouched.
        #expect(try await repo.git("branch", "--show-current") == "main")
    }

    @Test func sameKeyFromAnotherSiteGetsDistinctBranch() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        let first = try await repo.manager.prepareWorktree(for: ticket("PLAT-1"), repository: repo.config)
        let second = try await repo.manager.prepareWorktree(for: ticket("PLAT-1", source: "other.atlassian.net"), repository: repo.config)
        #expect(first.branch == "feat/PLAT-1")
        #expect(second.branch == "feat/PLAT-1-2")
        #expect(first.worktreePath != second.worktreePath)
    }

    @Test func hostileIDsAreSanitized() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        let workspace = try await repo.manager.prepareWorktree(for: ticket("../../etc/passwd -rf"), repository: repo.config)
        #expect(workspace.branch == "feat/etc-passwd-rf")
        #expect(workspace.worktreePath.hasPrefix(repo.worktrees.path))
    }

    @Test func repositoryHooksDoNotRun() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        let marker = repo.root.appending(path: "HOOK_RAN")
        let hook = repo.repo.appending(path: ".git/hooks/post-checkout")
        try "#!/bin/sh\ntouch '\(marker.path)'\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)

        _ = try await repo.manager.prepareWorktree(for: ticket("PLAT-9"), repository: repo.config)

        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func missingOrOptionLikeBaseBranchIsRejected() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        var config = repo.config
        config.baseBranch = "develop"
        await #expect(throws: WorkspaceError.baseBranchMissing("develop")) {
            _ = try await repo.manager.prepareWorktree(for: ticket("PLAT-2"), repository: config)
        }
        config.baseBranch = "--upload-pack=evil"
        await #expect(throws: WorkspaceError.invalidRef("--upload-pack=evil")) {
            _ = try await repo.manager.prepareWorktree(for: ticket("PLAT-2"), repository: config)
        }
    }

    @Test(arguments: [
        ("PLAT-182", "plat-182"),
        ("  Fix: the BUG!! ", "fix-the-bug"),
        ("...", "ticket"),
        ("a/../b", "a-b"),
        ("ünïcode", "n-code"),
    ])
    func slugs(input: String, expected: String) {
        #expect(GitWorktreeManager.slug(input, maxLength: 50) == expected)
    }
}

struct BaseBranchTests {
    @Test func listsBranchesNewestFirstWithoutHEAD() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        try await repo.git("branch", "old-release")
        try await repo.git("checkout", "-q", "-b", "develop")
        try "newer\n".write(to: repo.repo.appending(path: "new.txt"), atomically: true, encoding: .utf8)
        try await repo.git("add", "-A")
        try await repo.git("-c", "user.email=a@b", "-c", "user.name=u", "-c", "commit.gpgsign=false",
                           "commit", "-qm", "newer", "--date=2099-01-01T00:00:00")
        try await repo.git("update-ref", "refs/remotes/origin/develop", "develop")
        try await repo.git("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/develop")

        let branches = try await repo.manager.branches(inRepositoryAt: repo.repo.path)

        #expect(Set(branches.map(\.name)) == ["develop", "origin/develop", "main", "old-release"])
        #expect(branches.first { $0.name == "origin/develop" }?.isRemote == true)
        #expect(branches.first { $0.name == "develop" }?.isRemote == false)
        let develop = try #require(branches.firstIndex { $0.name == "develop" })
        let main = try #require(branches.firstIndex { $0.name == "main" })
        #expect(branches[develop].lastCommitDate >= branches[main].lastCommitDate)
    }

    @Test func perTicketBaseOverridesRepositorySetting() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        try await repo.git("checkout", "-q", "-b", "develop")
        try "dev only\n".write(to: repo.repo.appending(path: "dev.txt"), atomically: true, encoding: .utf8)
        try await repo.git("add", "-A")
        try await repo.git("-c", "user.email=a@b", "-c", "user.name=u", "commit", "-qm", "dev")
        let developHead = try await repo.git("rev-parse", "develop")

        let workspace = try await repo.manager.prepareWorktree(for: .sample(), repository: repo.config, baseBranch: "develop")

        #expect(repo.config.baseBranch == "main")
        #expect(workspace.baseBranch == "develop")
        #expect(workspace.baseCommit == developHead)
        #expect(FileManager.default.fileExists(atPath: URL(filePath: workspace.worktreePath).appending(path: "dev.txt").path))
    }
}
