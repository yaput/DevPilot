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
        // Restarting goes back through investigation and a fresh approval. Returning to
        // `approved` (to retry implementation) is only offered through
        // `AppDatabase.returnToApprovedPlan`, which re-checks the approval.
        case .failed: [.selected, .approved, .cancelled]
        case .cancelled: [.selected, .approved]
        case .rejected: [.selected]
        }
    }

    public func canTransition(to next: WorkflowState) -> Bool {
        allowedNextStates.contains(next)
    }

    /// States in which an agent process is (or was, before a crash) executing. `validating`
    /// and `reviewing` are resting states until M5 runs tests and reviews in them; crash
    /// recovery must not fail tickets that are simply waiting there.
    public var isAgentRunning: Bool {
        switch self {
        case .investigating, .implementing: true
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

public enum WorkflowError: Error, Equatable, Sendable, LocalizedError {
    case unknownTicket(String)
    case illegalTransition(from: WorkflowState, to: WorkflowState)
    /// The plan being approved is not the latest decision document.
    case planHashMismatch
    case decisionDocumentNotAllowed(in: WorkflowState)
    case implementationBlocked(ImplementationGate.BlockReason)

    public var errorDescription: String? {
        switch self {
        case .unknownTicket(let id): "Unknown ticket \(id)."
        case .illegalTransition(let from, let to): "Can't go from \(from.displayName) to \(to.displayName)."
        case .planHashMismatch: "The plan changed since you opened it. Review the latest version."
        case .decisionDocumentNotAllowed(let state): "A new plan can't be saved while the ticket is \(state.displayName)."
        case .implementationBlocked(let reason):
            switch reason {
            case .wrongState(let state): "Implementation needs an approved plan; the ticket is \(state.displayName)."
            case .missingPlan: "There is no plan to implement."
            case .missingApproval: "The plan has not been approved."
            case .planChangedSinceApproval: "The plan changed after it was approved. Approve the latest version first."
            }
        }
    }
}
