import Foundation

/// Append-only audit record of everything that happened to a ticket.
public struct WorkflowEvent: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case transition
        case approval
        /// User-supplied answers to clarifying questions, fed into the next investigation.
        case clarification
    }

    public let id: Int64
    public let ticketID: String
    public let kind: Kind
    public let fromState: WorkflowState?
    public let toState: WorkflowState?
    public let message: String
    public let createdAt: Date

    public init(
        id: Int64,
        ticketID: String,
        kind: Kind,
        fromState: WorkflowState?,
        toState: WorkflowState?,
        message: String,
        createdAt: Date
    ) {
        self.id = id
        self.ticketID = ticketID
        self.kind = kind
        self.fromState = fromState
        self.toState = toState
        self.message = message
        self.createdAt = createdAt
    }
}
