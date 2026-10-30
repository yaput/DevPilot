import Foundation

public struct InvestigationRequest: Sendable {
    public let ticket: Ticket
    public let workspace: TicketWorkspace
    public let previousPlan: DecisionDocument?
    /// Reviewer feedback and clarification answers, oldest first.
    public let guidance: [String]
    /// Where the raw agent transcript is written (outside the worktree).
    public let logURL: URL

    public init(ticket: Ticket, workspace: TicketWorkspace, previousPlan: DecisionDocument?, guidance: [String], logURL: URL) {
        self.ticket = ticket
        self.workspace = workspace
        self.previousPlan = previousPlan
        self.guidance = guidance
        self.logURL = logURL
    }
}

/// A coding agent DevPilot can drive. Investigation is strictly read-only.
public protocol AgentRunner: Sendable {
    func investigate(
        _ request: InvestigationRequest,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> (Investigation, AgentRunStats)
}

public enum AgentError: Error, Equatable, LocalizedError {
    case notConfigured(String)
    case notLoggedIn(String)
    case timedOut(minutes: Int)
    case failed(String)
    case invalidOutput(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let reason): reason
        case .notLoggedIn(let detail): "Claude Code is not logged in. Run `claude` in Terminal and log in, then try again. (\(detail))"
        case .timedOut(let minutes): "The agent did not finish within \(minutes) minutes and was stopped."
        case .failed(let message): "The agent failed: \(message)"
        case .invalidOutput(let message): "The agent returned an unusable result: \(message)"
        }
    }
}

/// Used when no agent executable is available, so the reason surfaces when a run is started.
public struct UnavailableAgentRunner: AgentRunner {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public func investigate(_ request: InvestigationRequest, onProgress: @escaping @Sendable (String) -> Void) async throws -> (Investigation, AgentRunStats) {
        throw AgentError.notConfigured(reason)
    }
}
