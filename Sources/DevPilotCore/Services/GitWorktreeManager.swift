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
    static let branchPrefix = "devpilot/"

    private let worktreeRoot: URL
    private let git: URL

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
        guard let topLevel = try? await run(["rev-parse", "--show-toplevel"], in: url) else {
            if (try? await run(["rev-parse", "--is-bare-repository"], in: url)) == "true" {
                throw WorkspaceError.bareRepository(path)
            }
            throw WorkspaceError.notAGitRepository(path)
        }
        guard Self.realPath(topLevel) == Self.realPath(url.path) else {
            throw WorkspaceError.notRepositoryRoot(path: path, root: topLevel)
        }
        var defaultBranch = try? await run(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], in: url)
        if let remote = defaultBranch, remote.hasPrefix("origin/") {
            defaultBranch = String(remote.dropFirst("origin/".count))
        }
        if defaultBranch?.isEmpty ?? true {
            defaultBranch = try? await run(["branch", "--show-current"], in: url)
        }
        return RepositoryInspection(topLevel: topLevel, defaultBranch: defaultBranch?.isEmpty == false ? defaultBranch : nil)
    }

    /// Creates `devpilot/<provider>-<id>` from the repository's base branch in
    /// `<worktreeRoot>/<repo>/<provider>-<id>`, adding `-2`, `-3`… if the name is taken.
    public func prepareWorktree(for ticket: Ticket, repository: RepositoryConfig, now: Date = Date()) async throws -> TicketWorkspace {
        let repoURL = URL(filePath: repository.path, directoryHint: .isDirectory)
        _ = try await inspect(path: repository.path)

        let base = repository.baseBranch.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty, !base.hasPrefix("-") else { throw WorkspaceError.invalidRef(base) }
        guard let baseCommit = try? await run(["rev-parse", "--verify", "--quiet", "\(base)^{commit}"], in: repoURL) else {
            throw WorkspaceError.baseBranchMissing(base)
        }

        let repoDirectory = worktreeRoot.appending(path: Self.slug(repository.name, maxLength: 40), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repoDirectory, withIntermediateDirectories: true)
        let rootReal = Self.realPath(worktreeRoot.path)
        let name = "\(ticket.provider.rawValue)-\(Self.slug(ticket.externalID, maxLength: 50))"

        for attempt in 1...50 {
            let suffix = attempt == 1 ? "" : "-\(attempt)"
            let branch = Self.branchPrefix + name + suffix
            let path = repoDirectory.appending(path: name + suffix, directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: path.path) { continue }
            if (try? await run(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], in: repoURL)) != nil { continue }

            guard (try? await run(["check-ref-format", "--branch", branch], in: repoURL)) != nil else {
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

    // MARK: - Helpers

    @discardableResult
    func run(_ arguments: [String], in directory: URL) async throws -> String {
        let result = try await ProcessRunner.run(ProcessRequest(
            executable: git, arguments: arguments, workingDirectory: directory,
            environment: Self.environment(), timeout: .seconds(120)
        ))
        guard result.succeeded else {
            let message = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw WorkspaceError.git("git \(arguments.joined(separator: " ")): \(message.isEmpty ? "exit \(result.termination)" : message)")
        }
        return result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// git needs HOME (for user config) and nothing else. Never prompts for credentials.
    static func environment() -> [String: String] {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return ["HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "GIT_TERMINAL_PROMPT": "0"]
    }

    /// Lowercase `[a-z0-9_-]`, no leading/trailing dashes, never empty. Safe as a path
    /// component and a ref component.
    static func slug(_ text: String, maxLength: Int) -> String {
        var result = ""
        for character in text.lowercased() {
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
