import Foundation

/// Per-ticket workflow state. All legal transitions are defined in `allowedNextStates`;
/// nothing else in the app may move a ticket between states.
public enum WorkflowState: String, Codable, Sendable, CaseIterable {
    case discovered
    case selected
    case investigating
    case needsClarification = "needs_clarification"
    case planReady = "plan_ready"
    case awaitingPlanApproval = "awaiting_plan_approval"
    case approved
    case implementing
    case validating
    case reviewing
    case readyForHumanReview = "ready_for_human_review"
    case completeManual = "complete_manual"
    case failed
    case cancelled
    case rejected
    case needsRevision = "needs_revision"

    public var allowedNextStates: Set<WorkflowState> {
        switch self {
        case .discovered: [.selected, .cancelled]
        case .selected: [.investigating, .cancelled]
        case .investigating: [.needsClarification, .planReady, .failed, .cancelled]
        // Clarification only ever leads back to investigation, never towards implementation.
        case .needsClarification: [.investigating, .cancelled]
        case .planReady: [.awaitingPlanApproval, .cancelled]
        case .awaitingPlanApproval: [.approved, .needsRevision, .rejected, .cancelled]
        case .needsRevision: [.investigating, .cancelled]
        case .approved: [.implementing, .cancelled]
        case .implementing: [.validating, .failed, .cancelled]
        // `implementing` from validating/reviewing is the bounded fix-retry loop.
        case .validating: [.reviewing, .implementing, .failed, .cancelled]
        case .reviewing: [.readyForHumanReview, .implementing, .failed, .cancelled]
        case .readyForHumanReview: [.completeManual, .cancelled]
        case .completeManual: []
        // Restarting goes back through investigation and a fresh approval.
        case .failed: [.selected, .cancelled]
        case .cancelled: [.selected]
        case .rejected: [.selected]
        }
    }

    public func canTransition(to next: WorkflowState) -> Bool {
        allowedNextStates.contains(next)
    }

    /// States in which an agent or command is (or was, before a crash) executing.
    public var isAgentRunning: Bool {
        switch self {
        case .investigating, .implementing, .validating, .reviewing: true
        default: false
        }
    }

    public var displayName: String {
        switch self {
        case .discovered: "Discovered"
        case .selected: "Selected"
        case .investigating: "Investigating"
        case .needsClarification: "Needs clarification"
        case .planReady: "Plan ready"
        case .awaitingPlanApproval: "Awaiting approval"
        case .approved: "Approved"
        case .implementing: "Implementing"
        case .validating: "Validating"
        case .reviewing: "Reviewing"
        case .readyForHumanReview: "Ready for review"
        case .completeManual: "Complete"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .rejected: "Rejected"
        case .needsRevision: "Needs revision"
        }
    }
}

public enum WorkflowError: Error, Equatable, Sendable {
    case unknownTicket(String)
    case illegalTransition(from: WorkflowState, to: WorkflowState)
    /// The plan being approved is not the latest decision document.
    case planHashMismatch
    case decisionDocumentNotAllowed(in: WorkflowState)
}
