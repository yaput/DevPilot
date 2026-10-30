import Foundation

/// Read-only source of tickets assigned to the current user.
public protocol TicketProvider: Sendable {
    var kind: TicketProviderKind { get }
    func assignedTickets() async throws -> [Ticket]
    /// Accepts the external ID (`ABC-12`, `4211`) or the full ticket ID.
    func ticket(id: String) async throws -> Ticket
    /// Verifies credentials and returns a short human-readable identity, e.g. "Jane Doe on acme.atlassian.net".
    func checkConnection() async throws -> String
}

extension TicketProvider {
    /// `jira:acme.atlassian.net/ABC-12` → `ABC-12`; external IDs pass through unchanged.
    func externalID(from id: String) -> String {
        id.split(separator: "/").last.map(String.init) ?? id
    }
}

public enum TicketProviderError: Error, Equatable, Sendable, LocalizedError {
    case notConfigured(String)
    case unauthorized
    case forbidden(String)
    case notFound(String)
    case rateLimited
    case http(status: Int, message: String)
    case transport(String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let reason): "Not configured: \(reason)"
        case .unauthorized: "The API token was rejected (401). Check it in Settings."
        case .forbidden(let message): "Access denied (403)\(message.isEmpty ? "" : ": \(message)")"
        case .notFound(let what): "Not found: \(what)"
        case .rateLimited: "Rate limited by the provider. Try again in a minute."
        case .http(let status, let message): "HTTP \(status)\(message.isEmpty ? "" : ": \(message)")"
        case .transport(let message): "Network error: \(message)"
        case .invalidResponse(let message): "Unexpected response: \(message)"
        }
    }
}

/// Stands in for a provider that is enabled but cannot run, so the reason shows up in sync status.
public struct UnconfiguredTicketProvider: TicketProvider {
    public let kind: TicketProviderKind
    public let reason: String

    public init(kind: TicketProviderKind, reason: String) {
        self.kind = kind
        self.reason = reason
    }

    public func assignedTickets() async throws -> [Ticket] { throw TicketProviderError.notConfigured(reason) }
    public func ticket(id: String) async throws -> Ticket { throw TicketProviderError.notConfigured(reason) }
    public func checkConnection() async throws -> String { throw TicketProviderError.notConfigured(reason) }
}
