import Foundation

/// Renders an investigation as the decision document the user approves. Deterministic: the
/// same input always produces the same text, and therefore the same content hash.
public enum DecisionDocumentRenderer {
    public static func render(_ investigation: Investigation, ticket: Ticket, workspace: TicketWorkspace) -> String {
        var lines: [String] = []
        lines.append("# Decision record: \(ticket.title)")
        lines.append("")
        lines.append("- Ticket: [\(ticket.externalID)](\(ticket.url.absoluteString)) (\(ticket.provider.displayName))")
        lines.append("- Repository: \(workspace.repositoryName), branch `\(workspace.branch)` from `\(workspace.baseBranch)` at `\(workspace.baseCommit.prefix(12))`")
        lines.append("- Outcome: \(investigation.needsClarification ? "**Needs clarification** (implementation blocked)" : "Plan ready for approval")")

        section("Summary", into: &lines) { [investigation.summary] }
        if !investigation.clarifyingQuestions.isEmpty {
            list("Clarifying questions (blocking)", investigation.clarifyingQuestions, numbered: true, into: &lines)
        }
        list("Requirements", investigation.requirements, into: &lines)
        list("Assumptions", investigation.assumptions, into: &lines)
        list("Impacted files", investigation.impactedFiles.map { "`\($0.path)`: \($0.reason)" }, into: &lines)
        list("Implementation steps", investigation.implementationSteps, numbered: true, into: &lines)
        list("Alternatives considered", investigation.alternatives.map { "**\($0.approach)**: \($0.whyNotChosen)" }, into: &lines)
        list("Trade-offs", investigation.tradeoffs, into: &lines)
        list("Risks", investigation.risks, into: &lines)
        list("Test plan", investigation.testPlan, into: &lines)
        section("Rollback", into: &lines) { [investigation.rollback] }
        list("Open questions", investigation.openQuestions, into: &lines)
        return lines.joined(separator: "\n") + "\n"
    }

    private static func section(_ title: String, into lines: inout [String], body: () -> [String]) {
        lines.append("")
        lines.append("## \(title)")
        lines.append("")
        let text = body().map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        lines.append(contentsOf: text.isEmpty ? ["_None._"] : text)
    }

    private static func list(_ title: String, _ items: [String], numbered: Bool = false, into lines: inout [String]) {
        section(title, into: &lines) {
            items.enumerated().map { index, item in
                let text = item.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
                return (numbered ? "\(index + 1). " : "- ") + text
            }
        }
    }
}
