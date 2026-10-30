import Foundation

/// Read-only source of tickets assigned to the current user.
public protocol TicketProvider: Sendable {
    var kind: TicketProviderKind { get }
    func assignedTickets() async throws -> [Ticket]
    func ticket(id: String) async throws -> Ticket
}

public enum TicketProviderError: Error, Equatable, Sendable {
    case notFound(String)
    case unauthorized
    case transport(String)
    case invalidResponse(String)
}
