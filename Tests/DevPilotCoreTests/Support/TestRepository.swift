import Foundation
@testable import DevPilotCore

/// A throwaway git repository with one commit on `main`, plus a worktree root, under a temp folder.
struct TestRepository {
    let root: URL
    let repo: URL
    let worktrees: URL

    /// `base` defaults to the temp folder; live sandbox tests pass a folder under HOME, because the
    /// sandbox treats temp folders as writable.
    init(files: [String: String] = ["README.md": "# Test\n"], base: URL = FileManager.default.temporaryDirectory) async throws {
        root = base.appending(path: "devpilot-git-\(UUID().uuidString)", directoryHint: .isDirectory)
        repo = root.appending(path: "repo", directoryHint: .isDirectory)
        worktrees = root.appending(path: "worktrees", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        for (name, contents) in files {
            let url = repo.appending(path: name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        try await git("init", "-q", "-b", "main")
        try await git("add", "-A")
        try await git("-c", "user.email=test@example.com", "-c", "user.name=Test", "commit", "-q", "-m", "init")
    }

    var config: RepositoryConfig {
        RepositoryConfig(id: "repo-1", name: "Test Repo", path: repo.path, baseBranch: "main")
    }

    var manager: GitWorktreeManager {
        GitWorktreeManager(worktreeRoot: worktrees)
    }

    @discardableResult
    func git(_ arguments: String..., in directory: URL? = nil) async throws -> String {
        try await GitWorktreeManager(worktreeRoot: worktrees).run(arguments, in: directory ?? repo)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
