import Foundation

public struct RepositoryConfig: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// Absolute path to the repository's top-level directory.
    public var path: String
    /// Branch (or other ref) new ticket worktrees start from.
    public var baseBranch: String

    public init(id: String = UUID().uuidString, name: String, path: String, baseBranch: String) {
        self.id = id
        self.name = name
        self.path = path
        self.baseBranch = baseBranch
    }
}

/// Routes tickets to a repository. Jira rules can match a project key; a rule with an empty
/// key is the default for every ticket from that provider.
public struct RepositoryRule: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var provider: TicketProviderKind
    public var projectKey: String
    public var repositoryID: String

    public init(id: String = UUID().uuidString, provider: TicketProviderKind, projectKey: String = "", repositoryID: String) {
        self.id = id
        self.provider = provider
        self.projectKey = projectKey
        self.repositoryID = repositoryID
    }
}

public struct WorkspaceSettings: StoredSettings {
    public static let storageKey = "workspaceSettings"
    public static let defaultWorktreeRoot = "~/DevPilot/worktrees"

    public var repositories: [RepositoryConfig] = []
    public var rules: [RepositoryRule] = []
    public var worktreeRoot = Self.defaultWorktreeRoot

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        repositories = try container.decodeIfPresent([RepositoryConfig].self, forKey: .repositories) ?? repositories
        rules = try container.decodeIfPresent([RepositoryRule].self, forKey: .rules) ?? rules
        worktreeRoot = try container.decodeIfPresent(String.self, forKey: .worktreeRoot) ?? worktreeRoot
    }

    public func repository(id: String) -> RepositoryConfig? {
        repositories.first { $0.id == id }
    }

    public var resolvedWorktreeRoot: URL {
        let path = (worktreeRoot.isEmpty ? Self.defaultWorktreeRoot : worktreeRoot) as NSString
        return URL(filePath: path.expandingTildeInPath, directoryHint: .isDirectory).standardizedFileURL
    }

    /// Project-key rule, then provider default, then the only repository if there is just one.
    public func suggestedRepository(for ticket: Ticket) -> RepositoryConfig? {
        let key = Self.projectKey(of: ticket)
        let providerRules = rules.filter { $0.provider == ticket.provider }
        let match = providerRules.first { !$0.projectKey.isEmpty && $0.projectKey.caseInsensitiveCompare(key ?? "") == .orderedSame }
            ?? providerRules.first { $0.projectKey.isEmpty }
        if let match, let repository = repository(id: match.repositoryID) {
            return repository
        }
        return repositories.count == 1 ? repositories[0] : nil
    }

    /// `PLAT-182` → `PLAT`. Shortcut stories have no project key.
    public static func projectKey(of ticket: Ticket) -> String? {
        guard ticket.provider == .jira, let dash = ticket.externalID.lastIndex(of: "-") else { return nil }
        return String(ticket.externalID[..<dash])
    }
}

public struct AgentSettings: StoredSettings {
    public static let storageKey = "agentSettings"

    /// Path to the `claude` executable. Empty means auto-detect.
    public var claudePath = ""
    /// Model alias or ID. Empty means the account default.
    public var model = ""
    public var investigationTimeoutMinutes = 20

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        claudePath = try container.decodeIfPresent(String.self, forKey: .claudePath) ?? claudePath
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? model
        investigationTimeoutMinutes = try container.decodeIfPresent(Int.self, forKey: .investigationTimeoutMinutes) ?? investigationTimeoutMinutes
    }
}
