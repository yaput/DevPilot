import Foundation
import Testing
@testable import DevPilotCore

struct ImplementationGateTests {
    let plan = DecisionDocument(ticketID: "jira:ABC-1", version: 1, markdown: "# Plan\nDo the thing.", createdAt: Date())

    func approval(_ decision: ApprovalDecision, hash: String? = nil) -> Approval {
        Approval(ticketID: "jira:ABC-1", planHash: hash ?? plan.contentHash, decision: decision, notes: "", decidedAt: Date())
    }

    @Test func allowsApprovedMatchingPlan() {
        #expect(ImplementationGate.evaluate(state: .approved, latestDocument: plan, latestApproval: approval(.approved)) == .allowed)
    }

    @Test(arguments: WorkflowState.allCases.filter { $0 != .approved })
    func blocksEveryOtherState(state: WorkflowState) {
        #expect(
            ImplementationGate.evaluate(state: state, latestDocument: plan, latestApproval: approval(.approved))
                == .blocked(.wrongState(state))
        )
    }

    @Test func blocksWithoutPlan() {
        #expect(ImplementationGate.evaluate(state: .approved, latestDocument: nil, latestApproval: approval(.approved)) == .blocked(.missingPlan))
    }

    @Test func blocksWithoutApproval() {
        #expect(ImplementationGate.evaluate(state: .approved, latestDocument: plan, latestApproval: nil) == .blocked(.missingApproval))
        #expect(ImplementationGate.evaluate(state: .approved, latestDocument: plan, latestApproval: approval(.rejected)) == .blocked(.missingApproval))
        #expect(ImplementationGate.evaluate(state: .approved, latestDocument: plan, latestApproval: approval(.revisionRequested)) == .blocked(.missingApproval))
    }

    @Test func revisedPlanInvalidatesApproval() {
        let revised = DecisionDocument(ticketID: plan.ticketID, version: 2, markdown: plan.markdown + "\nAlso drop the table.", createdAt: Date())
        #expect(
            ImplementationGate.evaluate(state: .approved, latestDocument: revised, latestApproval: approval(.approved))
                == .blocked(.planChangedSinceApproval)
        )
    }

    @Test func hashIsStableAndContentSensitive() {
        #expect(DecisionDocument.hash("a") == DecisionDocument.hash("a"))
        #expect(DecisionDocument.hash("a") != DecisionDocument.hash("a "))
        #expect(plan.contentHash.count == 64)
    }
}
