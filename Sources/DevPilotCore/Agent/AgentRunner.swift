import Darwin
import Foundation

public struct InvestigationRequest: Sendable {
    public let ticket: Ticket
    public let workspace: TicketWorkspace
    public let previousPlan: DecisionDocument?
    /// Reviewer feedback and clarification answers, oldest first.
    public let guidance: [String]
    /// Where the raw agent transcript is written (outside the worktree).
    public let logURL: URL
    public let onLaunch: (@Sendable (pid_t) -> Void)?

    public init(
        ticket: Ticket, workspace: TicketWorkspace, previousPlan: DecisionDocument?, guidance: [String], logURL: URL,
        onLaunch: (@Sendable (pid_t) -> Void)? = nil
    ) {
        self.ticket = ticket
        self.workspace = workspace
        self.previousPlan = previousPlan
        self.guidance = guidance
        self.logURL = logURL
        self.onLaunch = onLaunch
    }
}

public struct ImplementationRequest: Sendable {
    public let ticket: Ticket
    public let workspace: TicketWorkspace
    /// The approved plan, exactly as approved.
    public let plan: DecisionDocument
    /// Command prefixes the agent may run, e.g. `./mvnw`, `pnpm`, `git diff`.
    public let allowedCommands: [String]
    /// The main repository's `.git` directory; the sandbox makes it read-only.
    public let commonGitDirectory: String
    public let tools: ToolEnvironment
    public let logURL: URL
    /// Set for a fix of an existing implementation: what to fix (failing tests, review findings).
    public let fixInstructions: String?
    public let onLaunch: (@Sendable (pid_t) -> Void)?

    public init(
        ticket: Ticket, workspace: TicketWorkspace, plan: DecisionDocument, allowedCommands: [String],
        commonGitDirectory: String, tools: ToolEnvironment, logURL: URL, fixInstructions: String? = nil,
        onLaunch: (@Sendable (pid_t) -> Void)? = nil
    ) {
        self.ticket = ticket
        self.workspace = workspace
        self.plan = plan
        self.allowedCommands = allowedCommands
        self.commonGitDirectory = commonGitDirectory
        self.tools = tools
        self.logURL = logURL
        self.fixInstructions = fixInstructions
        self.onLaunch = onLaunch
    }
}

public struct ReviewRequest: Sendable {
    public let ticket: Ticket
    public let workspace: TicketWorkspace
    public let plan: DecisionDocument
    /// The implementer's own account, to be checked rather than trusted.
    public let implementation: ImplementationReport?
    public let validation: ValidationResult
    /// `git diff` of the worktree against its base (truncated if very large).
    public let diff: String
    public let commonGitDirectory: String
    public let logURL: URL
    public let onLaunch: (@Sendable (pid_t) -> Void)?

    public init(
        ticket: Ticket, workspace: TicketWorkspace, plan: DecisionDocument, implementation: ImplementationReport?,
        validation: ValidationResult, diff: String, commonGitDirectory: String, logURL: URL,
        onLaunch: (@Sendable (pid_t) -> Void)? = nil
    ) {
        self.ticket = ticket
        self.workspace = workspace
        self.plan = plan
        self.implementation = implementation
        self.validation = validation
        self.diff = diff
        self.commonGitDirectory = commonGitDirectory
        self.logURL = logURL
        self.onLaunch = onLaunch
    }
}

/// A coding agent DevPilot can drive.
public protocol AgentRunner: Sendable {
    /// Strictly read-only.
    func investigate(
        _ request: InvestigationRequest,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> (Investigation, AgentRunStats)

    /// Writes only inside the ticket's worktree; never commits, pushes or reaches the network.
    func implement(
        _ request: ImplementationRequest,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> (ImplementationReport, AgentRunStats)

    /// A fresh, read-only session that checks the implementation against the approved plan.
    func review(
        _ request: ReviewRequest,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> (ReviewReport, AgentRunStats)
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

    public func implement(_ request: ImplementationRequest, onProgress: @escaping @Sendable (String) -> Void) async throws -> (ImplementationReport, AgentRunStats) {
        throw AgentError.notConfigured(reason)
    }

    public func review(_ request: ReviewRequest, onProgress: @escaping @Sendable (String) -> Void) async throws -> (ReviewReport, AgentRunStats) {
        throw AgentError.notConfigured(reason)
    }
}
