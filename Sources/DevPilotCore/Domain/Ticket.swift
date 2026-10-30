import Foundation

public enum TicketProviderKind: String, Codable, Sendable, CaseIterable, Comparable {
    case shortcut
    case jira

    public var displayName: String {
        switch self {
        case .shortcut: "Shortcut"
        case .jira: "Jira"
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct TicketComment: Codable, Sendable, Hashable {
    public let author: String
    public let body: String
    public let createdAt: Date

    public init(author: String, body: String, createdAt: Date) {
        self.author = author
        self.body = body
        self.createdAt = createdAt
    }
}

/// A ticket normalized from any provider. `id` is provider-prefixed and source-qualified
/// (`shortcut:acme/1234`, `jira:acme.atlassian.net/ABC-12`) so identities never collide across
/// providers, or across Jira sites / Shortcut workspaces when the user switches between them.
public struct Ticket: Identifiable, Codable, Sendable, Hashable {
    public let provider: TicketProviderKind
    /// Jira site host or Shortcut workspace slug the ticket was fetched from.
    public let source: String
    /// Shortcut story ID or Jira issue key.
    public let externalID: String
    public let title: String
    /// Normalized plain text / Markdown.
    public let description: String
    /// Provider-native status name. Not comparable across providers.
    public let status: String
    public let assignee: String?
    public let url: URL
    public let comments: [TicketComment]
    public let acceptanceCriteria: [String]
    public let fetchedAt: Date

    public var id: String { Self.makeID(provider: provider, source: source, externalID: externalID) }

    public static func makeID(provider: TicketProviderKind, source: String, externalID: String) -> String {
        "\(provider.rawValue):\(source)/\(externalID)"
    }

    public init(
        provider: TicketProviderKind,
        source: String,
        externalID: String,
        title: String,
        description: String,
        status: String,
        assignee: String?,
        url: URL,
        comments: [TicketComment],
        acceptanceCriteria: [String],
        fetchedAt: Date
    ) {
        self.provider = provider
        self.source = source
        self.externalID = externalID
        self.title = title
        self.description = description
        self.status = status
        self.assignee = assignee
        self.url = url
        self.comments = comments
        self.acceptanceCriteria = acceptanceCriteria
        self.fetchedAt = fetchedAt
    }
}
