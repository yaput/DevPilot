import Testing
@testable import DevPilotCore

struct WorkflowStateTests {
    @Test func rawValuesMatchSpecNames() {
        #expect(Set(WorkflowState.allCases.map(\.rawValue)) == [
            "discovered", "selected", "investigating", "needs_clarification", "plan_ready",
            "awaiting_plan_approval", "approved", "implementing", "validating", "reviewing",
            "ready_for_human_review", "complete_manual", "failed", "cancelled", "rejected", "needs_revision",
        ])
    }

    @Test func happyPathIsLegal() {
        let path: [WorkflowState] = [
            .discovered, .selected, .investigating, .planReady, .awaitingPlanApproval, .approved,
            .implementing, .validating, .reviewing, .readyForHumanReview, .completeManual,
        ]
        for (from, to) in zip(path, path.dropFirst()) {
            #expect(from.canTransition(to: to), "\(from) -> \(to) should be legal")
        }
    }

    @Test func onlyApprovedOrFixRetryCanEnterImplementation() {
        let entries = WorkflowState.allCases.filter { $0.canTransition(to: .implementing) }
        #expect(Set(entries) == [.approved, .validating, .reviewing])
    }

    @Test func clarificationCannotAdvanceTowardsImplementation() {
        #expect(WorkflowState.needsClarification.allowedNextStates == [.investigating, .cancelled])
    }

    @Test func onlyApprovalDecisionsLeaveAwaitingApproval() {
        #expect(WorkflowState.awaitingPlanApproval.allowedNextStates == [.approved, .needsRevision, .rejected, .cancelled])
        let entriesToApproved = WorkflowState.allCases.filter { $0.canTransition(to: .approved) }
        #expect(entriesToApproved == [.awaitingPlanApproval])
    }

    @Test func completeIsTerminal() {
        #expect(WorkflowState.completeManual.allowedNextStates.isEmpty)
    }

    @Test(arguments: WorkflowState.allCases.filter(\.isAgentRunning))
    func runningStatesCanFail(state: WorkflowState) {
        #expect(state.canTransition(to: .failed))
    }

    @Test func noSelfTransitions() {
        for state in WorkflowState.allCases {
            #expect(!state.canTransition(to: state))
        }
    }
}
