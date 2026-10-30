import Darwin
import Foundation

public enum WorkspaceError: Error, Equatable, LocalizedError {
    case repositoryMissing(String)
    case notAGitRepository(String)
    case notRepositoryRoot(path: String, root: String)
    case bareRepository(String)
    case invalidRef(String)
    case baseBranchMissing(String)
    case pathOutsideWorktreeRoot(String)
    case git(String)

    public var errorDescription: String? {
        switch self {
        case .repositoryMissing(let path): "Repository folder \(path) does not exist."
        case .notAGitRepository(let path): "\(path) is not a git repository."
        case .notRepositoryRoot(let path, let root): "\(path) is inside the repository at \(root). Add the top-level folder instead."
        case .bareRepository(let path): "\(path) is a bare repository."
        case .invalidRef(let ref): "'\(ref)' is not a valid branch name."
        case .baseBranchMissing(let branch): "Base branch '\(branch)' does not exist in the repository."
        case .pathOutsideWorktreeRoot(let path): "Refusing to create a worktree outside the worktrees folder: \(path)"
        case .git(let message): "git failed: \(message)"
        }
    }
}

public struct RepositoryInspection: Sendable, Equatable {
    public let topLevel: String
    public let defaultBranch: String?
}

/// Creates one isolated worktree and branch per ticket. Never commits, pushes or fetches.
public struct GitWorktreeManager: Sendable {
    public static let defaultGit = URL(filePath: "/usr/bin/git")

    private let worktreeRoot: URL
    let git: URL

    public init(worktreeRoot: URL, git: URL = defaultGit) {
        self.worktreeRoot = worktreeRoot
        self.git = git
    }

    /// Validates that `path` is the top level of a non-bare repository and suggests a base branch.
    public func inspect(path: String) async throws -> RepositoryInspection {
        let url = URL(filePath: path, directoryHint: .isDirectory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw WorkspaceError.repositoryMissing(path)
        }
        guard let topLevel = try await output(["rev-parse", "--show-toplevel"], in: url) else {
            if (try await output(["rev-parse", "--is-bare-repository"], in: url)) == "true" {
                throw WorkspaceError.bareRepository(path)
            }
            throw WorkspaceError.notAGitRepository(path)
        }
        guard Self.realPath(topLevel) == Self.realPath(url.path) else {
            throw WorkspaceError.notRepositoryRoot(path: path, root: topLevel)
        }
        var defaultBranch = try await output(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], in: url)
        if let remote = defaultBranch, remote.hasPrefix("origin/") {
            defaultBranch = String(remote.dropFirst("origin/".count))
        }
        if defaultBranch?.isEmpty ?? true {
            defaultBranch = try await output(["branch", "--show-current"], in: url)
        }
        return RepositoryInspection(topLevel: topLevel, defaultBranch: defaultBranch?.isEmpty == false ? defaultBranch : nil)
    }

    /// Creates a branch named for the team's tracker integrations (`feat/sc-4211`, `fix/PLAT-190`)
    /// from the repository's base branch, in `<worktreeRoot>/<repo>/<provider>-<id>`, adding
    /// `-2`, `-3`… if the name is taken.
    /// `baseBranch` overrides the repository's configured base for this ticket.
    public func prepareWorktree(
        for ticket: Ticket,
        repository: RepositoryConfig,
        baseBranch: String? = nil,
        now: Date = Date()
    ) async throws -> TicketWorkspace {
        let repoURL = URL(filePath: repository.path, directoryHint: .isDirectory)
        _ = try await inspect(path: repository.path)

        let base = (baseBranch ?? repository.baseBranch).trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty, !base.hasPrefix("-") else { throw WorkspaceError.invalidRef(base) }
        guard let baseCommit = try await output(["rev-parse", "--verify", "--quiet", "\(base)^{commit}"], in: repoURL) else {
            throw WorkspaceError.baseBranchMissing(base)
        }

        let repoDirectory = worktreeRoot.appending(path: Self.slug(repository.name, maxLength: 40), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repoDirectory, withIntermediateDirectories: true)
        let rootReal = Self.realPath(worktreeRoot.path)
        let name = "\(ticket.provider.rawValue)-\(Self.slug(ticket.externalID, maxLength: 50))"
        let branchBase = Self.branchName(for: ticket)

        for attempt in 1...50 {
            let suffix = attempt == 1 ? "" : "-\(attempt)"
            let branch = branchBase + suffix
            let path = repoDirectory.appending(path: name + suffix, directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: path.path) { continue }
            if (try await output(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], in: repoURL)) != nil { continue }

            guard (try await output(["check-ref-format", "--branch", branch], in: repoURL)) != nil else {
                throw WorkspaceError.invalidRef(branch)
            }
            guard Self.realPath(repoDirectory.path).hasPrefix(rootReal + "/") else {
                throw WorkspaceError.pathOutsideWorktreeRoot(path.path)
            }
            // Hooks are disabled: a repository's post-checkout hook would otherwise run here.
            _ = try await run(
                ["-c", "core.hooksPath=/dev/null", "worktree", "add", "-b", branch, path.path, baseCommit],
                in: repoURL
            )
            return TicketWorkspace(
                ticketID: ticket.id, repositoryID: repository.id, repositoryName: repository.name,
                repositoryPath: repository.path, baseBranch: base, baseCommit: baseCommit, branch: branch,
                worktreePath: path.path, createdAt: now
            )
        }
        throw WorkspaceError.git("No free branch name for \(name)")
    }

    /// `feat/sc-4211`, `fix/sc-4230`, `chore/PLAT-190`. Shortcut and Jira integrations link
    /// branches (and their PRs) to tickets by these IDs.
    public static func branchName(for ticket: Ticket) -> String {
        let prefix = switch ticket.type {
        case .feature: "feat"
        case .bug: "fix"
        case .chore: "chore"
        }
        let id = switch ticket.provider {
        case .shortcut: "sc-" + slug(ticket.externalID, maxLength: 40)
        case .jira: refComponent(ticket.externalID, maxLength: 50)
        }
        return "\(prefix)/\(id)"
    }

    /// Removes a ticket's worktree with `git worktree remove`, which refuses if it has
    /// uncommitted or untracked changes, unless `discardingChanges` (the user confirmed losing
    /// them). The branch is deleted with `git branch -d`, which refuses if it has commits not
    /// merged anywhere; then it is kept. Returns whether the branch was deleted.
    @discardableResult
    public func removeWorktree(_ workspace: TicketWorkspace, discardingChanges: Bool = false) async throws -> Bool {
        let repository = URL(filePath: workspace.repositoryPath, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: workspace.worktreePath) {
            _ = try await run(["worktree", "remove"] + (discardingChanges ? ["--force"] : []) + [workspace.worktreePath], in: repository)
        } else {
            _ = try await output(["worktree", "prune"], in: repository)
        }
        return (try await output(["branch", "-d", workspace.branch], in: repository)) != nil
    }

    public struct Branch: Sendable, Hashable, Identifiable {
        public let name: String
        public let isRemote: Bool
        public let commit: String
        public let lastCommitDate: Date

        public var id: String { name }
    }

    /// Local and remote-tracking branches, most recently committed first. Read-only; nothing
    /// is fetched, so remote branches are as fresh as the last `git fetch`.
    public func branches(inRepositoryAt path: String) async throws -> [Branch] {
        let output = try await run(
            ["for-each-ref", "--sort=-committerdate", "--format=%(refname)%09%(objectname:short)%09%(committerdate:unix)",
             "refs/heads", "refs/remotes"],
            in: URL(filePath: path, directoryHint: .isDirectory)
        )
        return output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t").map(String.init)
            guard fields.count == 3, let seconds = TimeInterval(fields[2]), !fields[0].hasSuffix("/HEAD") else { return nil }
            let isRemote = fields[0].hasPrefix("refs/remotes/")
            let name = String(fields[0].dropFirst(isRemote ? "refs/remotes/".count : "refs/heads/".count))
            return Branch(name: name, isRemote: isRemote, commit: fields[1], lastCommitDate: Date(timeIntervalSince1970: seconds))
        }
    }

    // MARK: - Inspecting a worktree

    public func head(of worktree: String) async throws -> String {
        try await run(["rev-parse", "HEAD"], in: URL(filePath: worktree, directoryHint: .isDirectory))
    }

    /// The main repository's `.git` directory, shared by all its worktrees.
    public func commonGitDirectory(of worktree: String) async throws -> String {
        try await run(
            ["rev-parse", "--path-format=absolute", "--git-common-dir"],
            in: URL(filePath: worktree, directoryHint: .isDirectory)
        )
    }

    /// Uncommitted changes in the worktree, including untracked files.
    public func changedFiles(in worktree: String) async throws -> [ChangedFile] {
        let output = try await run(
            ["status", "--porcelain=v1", "-z", "--untracked-files=all"],
            in: URL(filePath: worktree, directoryHint: .isDirectory),
            trimming: false
        )
        return Self.parseStatus(output)
    }

    static func parseStatus(_ output: String) -> [ChangedFile] {
        var files: [ChangedFile] = []
        var entries = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        while let entry = entries.popFirst(), entry.count > 3 {
            let code = String(entry.prefix(2))
            let path = String(entry.dropFirst(3))
            let change: ChangedFile.Change
            if code == "??" {
                change = .untracked
            } else if code.contains("R") || code.contains("C") {
                change = .renamed
                _ = entries.popFirst()  // The original path follows a rename.
            } else if code.contains("A") {
                change = .added
            } else if code.contains("D") {
                change = .deleted
            } else if code.contains("M") {
                change = .modified
            } else {
                change = .other
            }
            files.append(ChangedFile(path: path, change: change))
        }
        return files
    }

    // MARK: - Helpers

    /// Like `run`, but a failing git command yields nil. Cancellation still propagates, so a
    /// stopped run is never mistaken for a git "no" (e.g. "not a valid branch name").
    func output(_ arguments: [String], in directory: URL) async throws -> String? {
        do {
            return try await run(arguments, in: directory)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    @discardableResult
    func run(_ arguments: [String], in directory: URL, trimming: Bool = true) async throws -> String {
        let result = try await ProcessRunner.run(ProcessRequest(
            executable: git, arguments: arguments, workingDirectory: directory,
            environment: Self.environment(), timeout: .seconds(120)
        ))
        guard result.succeeded else {
            let message = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw WorkspaceError.git("git \(arguments.joined(separator: " ")): \(message.isEmpty ? "exit \(result.termination)" : message)")
        }
        return trimming ? result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines) : result.stdoutText
    }

    /// git needs HOME (for user config) and nothing else. Never prompts for credentials.
    static func environment() -> [String: String] {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return ["HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "GIT_TERMINAL_PROMPT": "0"]
    }

    /// Lowercase `[a-z0-9_-]`, no leading/trailing dashes, never empty. Safe as a path
    /// component and a ref component.
    static func slug(_ text: String, maxLength: Int) -> String {
        refComponent(text.lowercased(), maxLength: maxLength)
    }

    /// Like `slug` but keeps letters' case, for Jira keys (`PLAT-182`).
    static func refComponent(_ text: String, maxLength: Int) -> String {
        var result = ""
        for character in text {
            if character.isASCII, character.isLetter || character.isNumber || character == "_" {
                result.append(character)
            } else if !result.hasSuffix("-") {
                result.append("-")
            }
        }
        let trimmed = String(result.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(maxLength))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "ticket" : trimmed
    }

    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return URL(filePath: path).standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
