import AppKit
import DevPilotCore
import SwiftUI

/// Ready for review: everything the user needs to decide, plus the next actions.
struct HandoffPanel: View {
    @Environment(AppModel.self) private var model
    let ticket: Ticket
    let detail: TicketDetailData
    let repositoryID: String

    @State private var fixing = false
    @State private var finishing = false

    var body: some View {
        let validation = detail.latestValidation?.validation
        let review = detail.latestReview?.review
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                if let validation {
                    Label(
                        validation.commands.isEmpty ? "No tests configured" : validation.passed ? "Tests passed" : "\(validation.failed.count) failing",
                        systemImage: validation.passed ? "checkmark.circle.fill" : "xmark.circle.fill"
                    )
                    .foregroundStyle(validation.commands.isEmpty ? Color.secondary : validation.passed ? .green : .red)
                }
                if let review {
                    Label(review.verdict == .approve ? "Review: approve" : "Review: changes requested",
                          systemImage: review.verdict == .approve ? "hand.thumbsup.fill" : "exclamationmark.bubble.fill")
                        .foregroundStyle(review.verdict == .approve ? .green : .orange)
                }
            }
            .font(.headline)
            Text("Review the changes in your IDE and commit them yourself. DevPilot never commits or pushes.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Fix with Claude…") { fixing = true }
                Button("Run Tests & Review Again") { model.startVerification(ticket.id, repositoryID: repositoryID) }
                Spacer()
                Button("Mark as Done…") { finishing = true }
                    .buttonStyle(.borderedProminent)
            }
        }
        .sheet(isPresented: $fixing) {
            FixRequestSheet(ticket: ticket, validation: validation, review: review) { instructions in
                model.fixWithClaude(ticket.id, repositoryID: repositoryID, instructions: instructions)
            }
        }
        .sheet(isPresented: $finishing) {
            MarkDoneSheet(ticket: ticket)
        }
    }
}

/// Tests and review results, shown from validation onwards.
struct VerificationSection: View {
    @Environment(AppModel.self) private var model
    let ticket: Ticket
    let detail: TicketDetailData

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let run = detail.latestValidation, let validation = run.validation {
                VStack(alignment: .leading, spacing: 6) {
                    Text(validation.fixAttempt > 0 ? "Tests (after fix attempt \(validation.fixAttempt))" : "Tests").font(.headline)
                    if validation.commands.isEmpty {
                        Text("No validation commands are configured for this repository.").foregroundStyle(.secondary)
                    }
                    ForEach(validation.commands, id: \.self) { result in
                        DisclosureGroup {
                            Text(result.outputTail.isEmpty ? "(no output)" : result.outputTail)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                        } label: {
                            HStack {
                                Image(systemName: result.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(result.passed ? .green : .red)
                                Text(result.command).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(result.timedOut ? "timed out" : "exit \(result.exitCode.map(String.init) ?? "?") · \(Int(result.durationSeconds))s")
                                    .font(.caption).foregroundStyle(.secondary)
                                Button("Full Log") { NSWorkspace.shared.open(URL(filePath: result.logPath)) }
                                    .controlSize(.mini)
                            }
                        }
                    }
                }
            }
            if let run = detail.latestReview, let review = run.review {
                ReviewView(review: review, run: run, worktree: detail.workspace?.worktreePath)
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ReviewView: View {
    @Environment(AppModel.self) private var model
    let review: ReviewReport
    let run: AgentRun
    let worktree: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Independent review").font(.headline)
                Text(review.verdict == .approve ? "Approve" : "Changes requested")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .foregroundStyle(review.verdict == .approve ? .green : .orange)
                    .background((review.verdict == .approve ? Color.green : .orange).opacity(0.15), in: Capsule())
                Spacer()
                Button("review.md") {
                    let file = URL(filePath: run.logPath).deletingPathExtension().appendingPathExtension("md")
                    NSWorkspace.shared.activateFileViewerSelecting([file])
                }
                .controlSize(.small)
            }
            Text(review.summary).textSelection(.enabled)
            if review.findings.isEmpty {
                Text("No findings.").foregroundStyle(.secondary)
            }
            ForEach(Array(review.findings.sorted { $0.severity < $1.severity }.enumerated()), id: \.offset) { _, finding in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        SeverityBadge(severity: finding.severity)
                        Text(finding.title).font(.callout.weight(.semibold))
                        if !finding.file.isEmpty {
                            Button("\(finding.file)\(finding.line > 0 ? ":\(finding.line)" : "")") { open(finding) }
                                .buttonStyle(.link)
                                .font(.caption.monospaced())
                                .help("Open in \(model.preferredEditor?.name ?? "editor")")
                        }
                    }
                    Text(finding.detail).font(.callout).textSelection(.enabled)
                    if !finding.suggestion.isEmpty {
                        Text("Suggestion: \(finding.suggestion)").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                .padding(.vertical, 2)
            }
            if !review.planCoverage.isEmpty {
                DisclosureGroup("Plan coverage (\(review.planCoverage.filter { $0.status == .done }.count)/\(review.planCoverage.count) done)") {
                    ForEach(review.planCoverage, id: \.self) { step in
                        Label {
                            Text(step.step + (step.note.isEmpty ? "" : " — \(step.note)"))
                        } icon: {
                            Image(systemName: step.status == .done ? "checkmark.circle" : step.status == .partial ? "circle.lefthalf.filled" : "circle")
                        }
                        .font(.callout)
                    }
                }
            }
            if !review.unresolvedRisks.isEmpty {
                Text("Unresolved risks").font(.subheadline.weight(.semibold))
                ForEach(review.unresolvedRisks, id: \.self) { Text("• \($0)").font(.callout) }
            }
        }
    }

    private func open(_ finding: ReviewReport.Finding) {
        guard let worktree, let editor = model.preferredEditor else { return }
        editor.open(URL(filePath: worktree).appending(path: finding.file), line: finding.line)
    }
}

struct SeverityBadge: View {
    let severity: ReviewReport.Finding.Severity

    var body: some View {
        Text(severity.rawValue.uppercased())
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }

    private var color: Color {
        switch severity {
        case .critical: .red
        case .major: .orange
        case .minor: .yellow
        case .nit: .secondary
        }
    }
}

/// Pick failing tests and findings to send back to Claude, plus free-form notes.
private struct FixRequestSheet: View {
    @Environment(\.dismiss) private var dismiss
    let ticket: Ticket
    let validation: ValidationResult?
    let review: ReviewReport?
    let submit: (String) -> Void

    @State private var includeFailingTests = true
    @State private var selectedFindings: Set<Int> = []
    @State private var notes = ""

    var body: some View {
        let findings = review?.findings.sorted { $0.severity < $1.severity } ?? []
        VStack(spacing: 0) {
            Form {
                if let validation, !validation.passed {
                    Toggle("Fix failing tests: \(validation.failed.map(\.command).joined(separator: ", "))", isOn: $includeFailingTests)
                }
                if !findings.isEmpty {
                    Section("Review findings") {
                        ForEach(Array(findings.enumerated()), id: \.offset) { index, finding in
                            Toggle(isOn: Binding(
                                get: { selectedFindings.contains(index) },
                                set: { if $0 { selectedFindings.insert(index) } else { selectedFindings.remove(index) } }
                            )) {
                                HStack {
                                    SeverityBadge(severity: finding.severity)
                                    Text(finding.title)
                                }
                            }
                        }
                    }
                }
                Section("Your instructions") {
                    TextEditor(text: $notes).frame(minHeight: 100)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Text("Claude fixes this in the same worktree; tests and review run again afterwards.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Fix") {
                    submit(instructions(findings))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(instructions(findings).isEmpty)
            }
            .padding(12)
        }
        .frame(width: 620, height: 560)
        .onAppear {
            // Pre-select what blocks a merge.
            selectedFindings = Set(findings.indices.filter { findings[$0].severity <= .major })
        }
    }

    private func instructions(_ findings: [ReviewReport.Finding]) -> String {
        var parts: [String] = []
        if includeFailingTests, let validation, !validation.passed {
            parts.append(VerificationService.fixInstructions(for: validation))
        }
        let chosen = findings.enumerated().filter { selectedFindings.contains($0.offset) }.map(\.element)
        if !chosen.isEmpty {
            parts.append("Address these review findings:\n" + chosen.map { finding in
                let location = finding.file.isEmpty ? "" : " (\(finding.file)\(finding.line > 0 ? ":\(finding.line)" : ""))"
                return "- [\(finding.severity.rawValue)] \(finding.title)\(location): \(finding.detail) Suggestion: \(finding.suggestion)"
            }.joined(separator: "\n"))
        }
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { parts.append("From the reviewer (a human):\n" + trimmed) }
        return parts.joined(separator: "\n\n")
    }
}

/// Mark done, showing whether the work is committed and pushed, and offer worktree cleanup.
private struct MarkDoneSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let ticket: Ticket

    @State private var status: BranchStatus?
    @State private var removeWorktree = true
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mark \(ticket.externalID) as done?").font(.title3.weight(.semibold))
            if let status {
                VStack(alignment: .leading, spacing: 4) {
                    line(status.commitsSinceBase > 0, "\(status.commitsSinceBase) commit\(status.commitsSinceBase == 1 ? "" : "s") on \(status.branch)",
                         warning: "No commits on \(status.branch) yet")
                    line(status.upstream != nil && status.unpushedCommits == 0,
                         status.upstream.map { "Pushed to \($0)" } ?? "",
                         warning: status.upstream == nil ? "Not pushed" : "\(status.unpushedCommits) commit\(status.unpushedCommits == 1 ? "" : "s") not pushed")
                    if let files = status.uncommittedFiles {
                        line(files == 0, "No uncommitted changes", warning: "\(files) uncommitted file\(files == 1 ? "" : "s") in the worktree")
                    }
                }
                if status.uncommittedFiles != nil {
                    Toggle("Remove the worktree", isOn: $removeWorktree)
                        .disabled((status.uncommittedFiles ?? 0) > 0)
                    Text((status.uncommittedFiles ?? 0) > 0
                         ? "Commit or discard the uncommitted changes first; git refuses to remove a worktree that has them."
                         : "The branch is kept unless it is fully merged or pushed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if loaded {
                Text("The worktree is already gone.").foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Mark as Done") {
                    let remove = removeWorktree && (status?.uncommittedFiles ?? 1) == 0
                    Task {
                        await model.markDone(ticket.id, removeWorktree: remove)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task {
            status = await model.branchStatus(ticket.id)
            removeWorktree = (status?.uncommittedFiles ?? 1) == 0
            loaded = true
        }
    }

    @ViewBuilder
    private func line(_ ok: Bool, _ text: String, warning: String) -> some View {
        Label(ok ? text : warning, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(ok ? .green : .orange)
    }
}

/// After "Mark as Done": a short summary of where the branch stands.
struct DonePanel: View {
    @Environment(AppModel.self) private var model
    let ticketID: String
    let hasWorktree: Bool
    @State private var status: BranchStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Done", systemImage: "checkmark.seal.fill").foregroundStyle(.green).font(.headline)
            if let status {
                Text("\(status.branch): \(status.commitsSinceBase) commit\(status.commitsSinceBase == 1 ? "" : "s")"
                     + (status.upstream.map { status.unpushedCommits == 0 ? ", pushed to \($0)" : ", \(status.unpushedCommits) not pushed" } ?? ", not pushed"))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .task(id: hasWorktree) { status = await model.branchStatus(ticketID) }
    }
}
