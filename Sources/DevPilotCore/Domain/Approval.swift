import CryptoKit
import Foundation

public struct DecisionDocument: Codable, Sendable, Hashable, Identifiable {
    public let ticketID: String
    public let version: Int
    /// The exact text the user reviews; `contentHash` covers only this.
    public let markdown: String
    public let contentHash: String
    public let createdAt: Date
    /// Structured source the Markdown was rendered from, when produced by an agent.
    public let investigation: Investigation?

    public init(ticketID: String, version: Int, markdown: String, createdAt: Date, investigation: Investigation? = nil) {
        self.ticketID = ticketID
        self.version = version
        self.markdown = markdown
        self.contentHash = Self.hash(markdown)
        self.createdAt = createdAt
        self.investigation = investigation
    }

    public var id: String { "\(ticketID)#v\(version)" }

    public static func hash(_ markdown: String) -> String {
        SHA256.hash(data: Data(markdown.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum ApprovalDecision: String, Codable, Sendable, CaseIterable {
    case approved
    case revisionRequested = "revision_requested"
    case rejected

    public var resultingState: WorkflowState {
        switch self {
        case .approved: .approved
        case .revisionRequested: .needsRevision
        case .rejected: .rejected
        }
    }
}

public struct Approval: Codable, Sendable, Hashable {
    public let ticketID: String
    /// Content hash of the exact decision document the user decided on.
    public let planHash: String
    public let decision: ApprovalDecision
    public let notes: String
    public let decidedAt: Date

    public init(ticketID: String, planHash: String, decision: ApprovalDecision, notes: String, decidedAt: Date) {
        self.ticketID = ticketID
        self.planHash = planHash
        self.decision = decision
        self.notes = notes
        self.decidedAt = decidedAt
    }
}

/// The single check that must pass before any code-writing agent runs.
public enum ImplementationGate {
    public enum Verdict: Equatable, Sendable {
        case allowed
        case blocked(BlockReason)
    }

    public enum BlockReason: Equatable, Sendable {
        case wrongState(WorkflowState)
        case missingPlan
        case missingApproval
        case planChangedSinceApproval
    }

    public static func evaluate(
        state: WorkflowState,
        latestDocument: DecisionDocument?,
        latestApproval: Approval?
    ) -> Verdict {
        guard state == .approved else { return .blocked(.wrongState(state)) }
        guard let latestDocument else { return .blocked(.missingPlan) }
        guard let latestApproval, latestApproval.decision == .approved else { return .blocked(.missingApproval) }
        // Recompute rather than trust the stored hash, so an edited plan can never ride on an old approval.
        guard latestApproval.planHash == DecisionDocument.hash(latestDocument.markdown) else {
            return .blocked(.planChangedSinceApproval)
        }
        return .allowed
    }
}
