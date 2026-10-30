import Foundation

/// The isolated git worktree a ticket's agent runs operate in.
public struct TicketWorkspace: Codable, Sendable, Hashable {
    public let ticketID: String
    public let repositoryID: String
    public let repositoryName: String
    public let repositoryPath: String
    public let baseBranch: String
    public let baseCommit: String
    public let branch: String
    public let worktreePath: String
    public let createdAt: Date

    public init(
        ticketID: String, repositoryID: String, repositoryName: String, repositoryPath: String,
        baseBranch: String, baseCommit: String, branch: String, worktreePath: String, createdAt: Date
    ) {
        self.ticketID = ticketID
        self.repositoryID = repositoryID
        self.repositoryName = repositoryName
        self.repositoryPath = repositoryPath
        self.baseBranch = baseBranch
        self.baseCommit = baseCommit
        self.branch = branch
        self.worktreePath = worktreePath
        self.createdAt = createdAt
    }
}

/// Structured result of a read-only investigation, produced by the agent against a JSON schema.
/// `DecisionDocumentRenderer` turns it into the Markdown the user approves.
public struct Investigation: Codable, Sendable, Hashable {
    public enum Outcome: String, Codable, Sendable {
        case planReady = "plan_ready"
        case needsClarification = "needs_clarification"
    }

    public struct ImpactedFile: Codable, Sendable, Hashable {
        public let path: String
        public let reason: String

        public init(path: String, reason: String) {
            self.path = path
            self.reason = reason
        }
    }

    public struct Alternative: Codable, Sendable, Hashable {
        public let approach: String
        public let whyNotChosen: String

        public init(approach: String, whyNotChosen: String) {
            self.approach = approach
            self.whyNotChosen = whyNotChosen
        }
    }

    public let outcome: Outcome
    public let summary: String
    public let requirements: [String]
    public let assumptions: [String]
    /// Questions that must be answered before a plan can be approved.
    public let clarifyingQuestions: [String]
    public let impactedFiles: [ImpactedFile]
    public let implementationSteps: [String]
    public let alternatives: [Alternative]
    public let tradeoffs: [String]
    public let risks: [String]
    public let testPlan: [String]
    public let rollback: String
    /// Non-blocking questions worth raising with the ticket author.
    public let openQuestions: [String]

    public init(
        outcome: Outcome, summary: String, requirements: [String], assumptions: [String],
        clarifyingQuestions: [String], impactedFiles: [ImpactedFile], implementationSteps: [String],
        alternatives: [Alternative], tradeoffs: [String], risks: [String], testPlan: [String],
        rollback: String, openQuestions: [String]
    ) {
        self.outcome = outcome
        self.summary = summary
        self.requirements = requirements
        self.assumptions = assumptions
        self.clarifyingQuestions = clarifyingQuestions
        self.impactedFiles = impactedFiles
        self.implementationSteps = implementationSteps
        self.alternatives = alternatives
        self.tradeoffs = tradeoffs
        self.risks = risks
        self.testPlan = testPlan
        self.rollback = rollback
        self.openQuestions = openQuestions
    }

    /// A plan is only approvable when the agent says it is ready and asked nothing blocking.
    public var needsClarification: Bool {
        outcome == .needsClarification || !clarifyingQuestions.isEmpty
    }
}

public struct AgentRun: Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case investigation
        case implementation
        case review
    }

    public enum Outcome: String, Codable, Sendable {
        case succeeded
        case failed
        case cancelled
        case timedOut = "timed_out"
        case interrupted
    }

    public let id: Int64
    public let ticketID: String
    public let kind: Kind
    public let startedAt: Date
    public let finishedAt: Date?
    public let outcome: Outcome?
    public let numTurns: Int?
    public let costUSD: Double?
    public let logPath: String
    public let errorMessage: String?

    public init(
        id: Int64, ticketID: String, kind: Kind, startedAt: Date, finishedAt: Date?, outcome: Outcome?,
        numTurns: Int?, costUSD: Double?, logPath: String, errorMessage: String?
    ) {
        self.id = id
        self.ticketID = ticketID
        self.kind = kind
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outcome = outcome
        self.numTurns = numTurns
        self.costUSD = costUSD
        self.logPath = logPath
        self.errorMessage = errorMessage
    }
}

/// Usage reported by the agent CLI for one run.
public struct AgentRunStats: Sendable, Hashable {
    public let numTurns: Int?
    /// API-equivalent cost reported by the CLI; informational on subscription plans.
    public let costUSD: Double?

    public init(numTurns: Int?, costUSD: Double?) {
        self.numTurns = numTurns
        self.costUSD = costUSD
    }
}
