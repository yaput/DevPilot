import AppKit
import DevPilotCore
import SwiftUI

struct TicketDetailView: View {
    @Environment(AppModel.self) private var model
    let ticket: Ticket
    @State private var detail = TicketDetailData()
    @State private var reviewingPlan: DecisionDocument?

    var body: some View {
        let state = model.state(of: ticket.id)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header(state: state)
                WorkflowPanel(ticket: ticket, state: state, detail: detail) { reviewingPlan = $0 }
                if detail.latestValidation != nil || detail.latestReview != nil {
                    VerificationSection(ticket: ticket, detail: detail)
                }
                if let run = detail.latestImplementation, let result = run.implementation {
                    ImplementationSection(run: run, result: result)
                }
                if let document = detail.document {
                    DecisionRecordSection(document: document, artifacts: model.artifacts)
                }
                TicketContentSection(ticket: ticket)
                HistorySection(events: detail.events, runs: detail.runs)
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: "\(ticket.id)|\(state.rawValue)|\(model.detailRevision)") {
            detail = await model.loadDetail(ticket.id)
        }
        .sheet(item: $reviewingPlan) { document in
            ApprovalSheet(ticket: ticket, document: document)
        }
    }

    private func header(state: WorkflowState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProviderBadge(provider: ticket.provider)
                Text(ticket.externalID).font(.callout.monospaced()).foregroundStyle(.secondary)
                    .help(ticket.source)
                Text("·").foregroundStyle(.secondary)
                Text(ticket.type.displayName).foregroundStyle(.secondary)
                Text("·").foregroundStyle(.secondary)
                Text(ticket.status).foregroundStyle(.secondary)
                Spacer()
                StateBadge(state: state)
            }
            Text(ticket.title).font(.title2.weight(.semibold))
            HStack(spacing: 16) {
                Link(destination: ticket.url) {
                    Label("Open in \(ticket.provider.displayName)", systemImage: "arrow.up.right.square")
                }
                Text("Fetched \(ticket.fetchedAt.formatted(.relative(presentation: .named)))")
                    .foregroundStyle(.secondary)
                if model.unassignedIDs.contains(ticket.id) {
                    Label("No longer assigned to you", systemImage: "person.crop.circle.badge.questionmark")
                        .foregroundStyle(.orange)
                }
            }
            .font(.callout)
        }
    }
}

// MARK: - Workflow panel

/// The "what can I do now" box: repository choice, investigation progress, clarification
/// answers and the entry point to plan review.
private struct WorkflowPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let ticket: Ticket
    let state: WorkflowState
    let detail: TicketDetailData
    let reviewPlan: (DecisionDocument) -> Void

    @State private var repositoryID: String?
    /// Base branch for this ticket's new worktree; starts as the repository's setting.
    @State private var baseBranch = ""
    @State private var answers = ""
    @State private var confirmingDiscard = false
    @State private var confirmingStartOver = false
    @State private var startOverStatus: BranchStatus?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                repositoryRow
                Divider()
                stateContent
                if canStartOver {
                    HStack {
                        Spacer()
                        Button("Start Over…") {
                            Task {
                                startOverStatus = await model.branchStatus(ticket.id)
                                confirmingStartOver = true
                            }
                        }
                        .controlSize(.small)
                        .help("Back to the start with a fresh worktree, no earlier plans or answers, and transcripts deleted.")
                    }
                }
                if let error = lastRunError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("Start \(ticket.externalID) over?", isPresented: $confirmingStartOver) {
            Button("Start Over", role: .destructive) { Task { await model.startOver(ticket.id) } }
        } message: {
            Text(startOverMessage)
        }
        .onAppear { repositoryID = repositoryID ?? model.workspaceSettings.suggestedRepository(for: ticket)?.id }
        .onChange(of: ticket.id) {
            repositoryID = model.workspaceSettings.suggestedRepository(for: ticket)?.id
            answers = ""
        }
    }

    // MARK: Repository

    @ViewBuilder
    private var repositoryRow: some View {
        if let workspace = detail.workspace {
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Worktree") {
                    Text(workspace.worktreePath).font(.callout.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                }
                LabeledContent("Branch") {
                    Text("\(workspace.branch) from \(workspace.baseBranch) @ \(workspace.baseCommit.prefix(8))")
                        .font(.callout.monospaced())
                }
                HStack {
                    // Investigation only reads; there is nothing to show before an implementation.
                    if detail.latestImplementation != nil {
                        Button("View Changes") { openWindow(id: AppWindow.changes, value: ticket.id) }
                    }
                    OpenWorktreeMenu(workspace: workspace)
                        .fixedSize()
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: workspace.worktreePath)])
                    }
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(workspace.worktreePath, forType: .string)
                    }
                    Spacer()
                    Button("Discard Worktree…", role: .destructive) { confirmingDiscard = true }
                        .disabled(state.isAgentRunning || model.isRunning(ticket.id))
                }
                .controlSize(.small)
                .confirmationDialog("Discard this worktree?", isPresented: $confirmingDiscard) {
                    Button("Discard Worktree", role: .destructive) { Task { await model.discardWorktree(ticket.id) } }
                } message: {
                    Text("""
                        Removes \(workspace.worktreePath). Git refuses if it has uncommitted changes, so nothing \
                        unsaved can be lost. Branch \(workspace.branch) is deleted only if it has no commits of its own. \
                        The next investigation creates a new worktree from the repository's current base branch.
                        """)
                }
            }
        } else if model.workspaceSettings.repositories.isEmpty {
            HStack {
                Label("No repositories set up yet.", systemImage: "folder.badge.questionmark")
                Spacer()
                SettingsLink { Text("Add Repository…") }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Repository", selection: $repositoryID) {
                    Text("Choose…").tag(String?.none)
                    ForEach(model.workspaceSettings.repositories) { repository in
                        Text(repository.name).tag(Optional(repository.id))
                    }
                }
                if let repository = repositoryID.flatMap(model.workspaceSettings.repository(id:)) {
                    BaseBranchField(title: "Base branch", branch: $baseBranch, repositoryPath: repository.path)
                }
            }
            .frame(maxWidth: 460)
            .onAppear { resetBaseBranch() }
            .onChange(of: repositoryID) { resetBaseBranch() }
        }
    }

    private func resetBaseBranch() {
        baseBranch = repositoryID.flatMap(model.workspaceSettings.repository(id:))?.baseBranch ?? ""
    }

    /// Any resting state with something to clear (also `selected` when earlier work exists).
    private var canStartOver: Bool {
        guard !state.isAgentRunning, !model.isRunning(ticket.id), ![.discovered, .completeManual].contains(state) else { return false }
        return state != .selected || detail.document != nil || !detail.runs.isEmpty || detail.workspace != nil
    }

    private var startOverMessage: String {
        var parts = ["A clean slate: the ticket goes back to the start. Earlier plans, answers, runs and history are cleared, transcripts and logs are deleted, and the next investigation starts without them."]
        if let workspace = detail.workspace {
            let files = startOverStatus?.uncommittedFiles ?? 0
            parts.append(files > 0
                ? "The worktree is removed, including \(files) uncommitted file\(files == 1 ? "" : "s"), which will be permanently lost."
                : "The worktree is removed (no uncommitted changes).")
            if let commits = startOverStatus?.commitsSinceBase, commits > 0 {
                parts.append("Branch \(workspace.branch) has \(commits) commit\(commits == 1 ? "" : "s") and is kept.")
            }
        }
        return parts.joined(separator: " ")
    }

    private var effectiveRepositoryID: String? {
        detail.workspace?.repositoryID ?? repositoryID
    }

    private var investigationCaption: String {
        let source = if let workspace = detail.workspace {
            "its existing worktree (from \(workspace.baseBranch) @ \(workspace.baseCommit.prefix(8)))"
        } else if effectiveRepositoryID != nil {
            "a new worktree from \(baseBranch.isEmpty ? "the repository's base branch" : baseBranch)"
        } else {
            "a new worktree"
        }
        return "Claude reads the repository in \(source). It cannot edit files or run commands during investigation."
    }

    // MARK: State-specific content

    @ViewBuilder
    private var stateContent: some View {
        switch state {
        case .discovered:
            HStack {
                Button("Select for Investigation") { Task { await model.select(ticket.id) } }
                    .buttonStyle(.borderedProminent)
                cancelButton
            }
        case .selected, .needsRevision:
            VStack(alignment: .leading, spacing: 8) {
                if state == .needsRevision {
                    Text("Revision requested. The next investigation gets your notes and the previous plan.")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    startButton(state == .needsRevision ? "Re-investigate" : "Start Investigation")
                    cancelButton
                }
                Text(investigationCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .investigating, .implementing:
            RunProgress(ticketID: ticket.id)
        case .validating, .reviewing where model.isRunning(ticket.id):
            RunProgress(ticketID: ticket.id)
        case .needsClarification:
            clarificationForm
        case .planReady, .awaitingPlanApproval:
            HStack {
                if let document = detail.document {
                    Button("Review Plan v\(document.version)…") { reviewPlan(document) }
                        .buttonStyle(.borderedProminent)
                }
                cancelButton
            }
        case .approved:
            implementForm
        case .validating, .reviewing:
            // Resting here: verification was interrupted, failed to start, or predates M5.
            HStack {
                Text(state == .validating ? "Implemented. Tests and review have not run yet." : "Tests ran; the review did not finish.")
                    .foregroundStyle(.secondary)
                if let id = effectiveRepositoryID {
                    Button(state == .validating ? "Run Tests & Review" : "Run Review") { model.startVerification(ticket.id, repositoryID: id) }
                        .buttonStyle(.borderedProminent)
                }
                cancelButton
            }
        case .readyForHumanReview:
            if let id = effectiveRepositoryID {
                HandoffPanel(ticket: ticket, detail: detail, repositoryID: id)
            }
        case .completeManual:
            DonePanel(ticketID: ticket.id, hasWorktree: detail.workspace != nil)
        case .failed, .cancelled, .rejected:
            HStack {
                Text(state == .rejected ? "Plan rejected." : "Stopped.")
                    .foregroundStyle(.secondary)
                if canRetryImplementation, let id = effectiveRepositoryID {
                    Button("Retry Implementation") { Task { await model.retryImplementation(ticket.id, repositoryID: id) } }
                        .buttonStyle(.borderedProminent)
                        .help("Goes back to the approved plan and implements it again in the same worktree.")
                }
                Button("Restart") { Task { await model.select(ticket.id) } }
                    .help("Start over from investigation.")
            }
        }
    }

    /// The last run was an implementation of a plan that is still approved.
    private var canRetryImplementation: Bool {
        state != .rejected && detail.runs.last?.kind == .implementation && detail.document != nil
    }

    private var implementForm: some View {
        let repository = effectiveRepositoryID.flatMap(model.workspaceSettings.repository(id:))
        let setup = repository?.setupCommands.filter(\.isEnabled).map(\.command) ?? []
        let commands = repository?.agentCommands.filter(\.isEnabled).map(\.command) ?? []
        return VStack(alignment: .leading, spacing: 8) {
            Label("Plan v\(detail.document?.version ?? 0) approved.", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
            if let repository {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Setup: " + (setup.isEmpty ? "none" : setup.joined(separator: "; ")))
                    Text("Claude may run: " + (commands.isEmpty ? "no commands (file edits only)" : commands.joined(separator: ", ")))
                    Text("Edits stay in this worktree. No commits, no pushes, no network.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack {
                    Button("Implement") { model.startImplementation(ticket.id, repositoryID: repository.id) }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isRunning(ticket.id))
                    SettingsLink { Text("Edit Commands…") }
                    cancelButton
                }
            } else {
                Label("This ticket's repository was removed from Settings. Add it again to implement.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
    }

    private func startButton(_ title: String) -> some View {
        Button(title) {
            if let id = effectiveRepositoryID { model.startInvestigation(ticket.id, repositoryID: id, baseBranch: baseBranch) }
        }
        .buttonStyle(.borderedProminent)
        .disabled(effectiveRepositoryID == nil || model.isRunning(ticket.id))
    }

    @ViewBuilder
    private var cancelButton: some View {
        if state.canTransition(to: .cancelled) {
            Button("Cancel Ticket", role: .destructive) { Task { await model.cancel(ticket.id) } }
        }
    }

    private var clarificationForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Implementation is blocked until these questions are answered.", systemImage: "questionmark.bubble.fill")
                .foregroundStyle(.orange)
                .font(.headline)
            ForEach(Array((detail.document?.investigation?.clarifyingQuestions ?? []).enumerated()), id: \.offset) { index, question in
                Text("\(index + 1). \(question)").textSelection(.enabled)
            }
            Text("Answer here, or update the ticket in \(ticket.provider.displayName) and refresh, then re-investigate.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $answers)
                .font(.body)
                .frame(minHeight: 90)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Button("Answer and Re-investigate") {
                    guard let id = effectiveRepositoryID else { return }
                    let text = answers.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task {
                        await model.answerClarification(ticket.id, answers: text, repositoryID: id)
                        answers = ""
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(answers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || effectiveRepositoryID == nil)
                Button("Re-investigate Without Answers") {
                    if let id = effectiveRepositoryID { model.startInvestigation(ticket.id, repositoryID: id) }
                }
                .disabled(effectiveRepositoryID == nil)
                .help("Use this after updating the ticket itself.")
                cancelButton
            }
        }
    }

    private var lastRunError: String? {
        guard [.failed, .cancelled, .validating, .reviewing].contains(state), !model.isRunning(ticket.id),
              let run = detail.runs.last, let outcome = run.outcome, outcome != .succeeded else { return nil }
        return run.errorMessage
    }
}

private struct RunProgress: View {
    @Environment(AppModel.self) private var model
    let ticketID: String

    /// One run can go through several phases (implement → test → fix → review).
    private var phase: String {
        switch model.state(of: ticketID) {
        case .investigating: "Investigating"
        case .implementing: "Implementing"
        case .validating: "Running tests"
        case .reviewing: "Reviewing"
        default: "Working"
        }
    }

    var body: some View {
        if let activity = model.activity[ticketID] {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    ProgressView().controlSize(.small)
                    TimelineView(.periodic(from: activity.startedAt, by: 1)) { context in
                        Text("\(phase)… \(Duration.seconds(context.date.timeIntervalSince(activity.startedAt)).formatted(.time(pattern: .minuteSecond)))")
                            .monospacedDigit()
                    }
                    Spacer()
                    Button("Stop", role: .destructive) { model.stopRun(ticketID) }
                }
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(activity.lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .foregroundStyle(index == activity.lines.count - 1 ? .primary : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        } else {
            // Running according to the database but not in this session: the app was restarted.
            Label("A run was in progress when DevPilot last quit. It will be stopped and marked failed on next launch.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Sections

private struct ImplementationSection: View {
    @Environment(\.openWindow) private var openWindow
    let run: AgentRun
    let result: ImplementationResult

    var body: some View {
        let report = result.report
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Implementation of plan v\(result.planVersion)").font(.headline)
                Text(report.outcome.rawValue.capitalized)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .foregroundStyle(report.outcome == .completed ? .green : .orange)
                    .background((report.outcome == .completed ? Color.green : .orange).opacity(0.15), in: Capsule())
                Spacer()
                Button("View Changes") { openWindow(id: AppWindow.changes, value: run.ticketID) }
                    .controlSize(.small)
                Button("Transcript") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: run.logPath)]) }
                    .controlSize(.small)
            }
            Text(report.summary).textSelection(.enabled)
            group("Changed files (\(result.changedFiles.count))") {
                ForEach(result.changedFiles, id: \.self) { file in
                    HStack(spacing: 6) {
                        Text(file.change.rawValue)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .leading)
                        Text(file.path).font(.callout.monospaced()).textSelection(.enabled)
                    }
                }
            }
            if !report.commands.isEmpty {
                group("Commands run") {
                    ForEach(report.commands, id: \.self) { command in
                        Label {
                            Text("`\(command.command)` \(command.note)")
                        } icon: {
                            Image(systemName: command.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(command.succeeded ? .green : .red)
                        }
                    }
                }
            }
            list("Deviations from the plan", report.deviations)
            list("Remaining work", report.remainingWork)
            list("Notes for the reviewer", report.notesForReviewer)
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func list(_ title: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            group(title) {
                ForEach(items, id: \.self) { Text("• \($0)").textSelection(.enabled) }
            }
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
        }
    }
}

private struct DecisionRecordSection: View {
    let document: DecisionDocument
    let artifacts: ArtifactStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Decision record v\(document.version)").font(.headline)
                Text(document.contentHash.prefix(12))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .help("SHA-256 of this exact text. Approval is bound to it.")
                Spacer()
                Button("Show File") {
                    let url = artifacts.decisionURL(for: document)
                    if !FileManager.default.fileExists(atPath: url.path) { try? artifacts.write(document) }
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .controlSize(.small)
            }
            MarkdownView(markdown: document.markdown)
                .padding(16)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct TicketContentSection: View {
    let ticket: Ticket

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            section("Description") {
                if ticket.description.isEmpty {
                    Text("No description.").foregroundStyle(.secondary)
                } else {
                    MarkdownView(markdown: ticket.description)
                }
            }
            section("Acceptance criteria") {
                if ticket.acceptanceCriteria.isEmpty {
                    Text("None found.").foregroundStyle(.secondary)
                }
                ForEach(ticket.acceptanceCriteria, id: \.self) { criterion in
                    Label(criterion, systemImage: "checkmark.circle")
                }
            }
            if !ticket.comments.isEmpty {
                section("Comments") {
                    ForEach(ticket.comments, id: \.self) { comment in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(comment.author) · \(comment.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            MarkdownView(markdown: comment.body)
                        }
                    }
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }
}

private struct HistorySection: View {
    let events: [WorkflowEvent]
    let runs: [AgentRun]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("History").font(.headline)
            ForEach(events) { event in
                HStack(alignment: .firstTextBaseline) {
                    Text(event.createdAt.formatted(date: .abbreviated, time: .standard))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 170, alignment: .leading)
                    if let to = event.toState {
                        StateBadge(state: to)
                    } else if event.kind == .clarification {
                        Label("Answers", systemImage: "text.bubble").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    }
                    Text(event.message)
                        .font(.callout)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
            if !runs.isEmpty {
                Text("Agent runs").font(.subheadline.weight(.semibold)).padding(.top, 8)
                ForEach(runs) { run in
                    HStack(spacing: 8) {
                        Text(run.startedAt.formatted(date: .abbreviated, time: .standard))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 170, alignment: .leading)
                        Text(run.kind.rawValue.capitalized).font(.callout)
                        Text(run.outcome?.rawValue.replacingOccurrences(of: "_", with: " ") ?? "running")
                            .font(.callout)
                            .foregroundStyle(run.outcome == .succeeded ? .green : run.outcome == nil ? .blue : .red)
                        if let finished = run.finishedAt {
                            Text(Duration.seconds(finished.timeIntervalSince(run.startedAt)).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let turns = run.numTurns {
                            Text("\(turns) turns").font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Transcript") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: run.logPath)])
                        }
                        .controlSize(.mini)
                        .disabled(!FileManager.default.fileExists(atPath: run.logPath))
                    }
                }
            }
        }
    }
}
