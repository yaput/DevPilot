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

        #expect(workspace.branch == "devpilot/jira-plat-182")
        #expect(workspace.worktreePath == repo.worktrees.appending(path: "test-repo/jira-plat-182").path)
        #expect(FileManager.default.fileExists(atPath: URL(filePath: workspace.worktreePath).appending(path: "README.md").path))
        let head = try await repo.git("rev-parse", "HEAD")
        #expect(workspace.baseCommit == head)
        let branch = try await repo.git("branch", "--show-current", in: URL(filePath: workspace.worktreePath))
        #expect(branch == "devpilot/jira-plat-182")
        // The main checkout is untouched.
        #expect(try await repo.git("branch", "--show-current") == "main")
    }

    @Test func sameKeyFromAnotherSiteGetsDistinctBranch() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        let first = try await repo.manager.prepareWorktree(for: ticket("PLAT-1"), repository: repo.config)
        let second = try await repo.manager.prepareWorktree(for: ticket("PLAT-1", source: "other.atlassian.net"), repository: repo.config)
        #expect(first.branch == "devpilot/jira-plat-1")
        #expect(second.branch == "devpilot/jira-plat-1-2")
        #expect(first.worktreePath != second.worktreePath)
    }

    @Test func hostileIDsAreSanitized() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        let workspace = try await repo.manager.prepareWorktree(for: ticket("../../etc/passwd -rf"), repository: repo.config)
        #expect(workspace.branch == "devpilot/jira-etc-passwd-rf")
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
