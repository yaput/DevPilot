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
    let ticket: Ticket
    let state: WorkflowState
    let detail: TicketDetailData
    let reviewPlan: (DecisionDocument) -> Void

    @State private var repositoryID: String?
    @State private var answers = ""

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                repositoryRow
                Divider()
                stateContent
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
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: workspace.worktreePath)])
                    }
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(workspace.worktreePath, forType: .string)
                    }
                }
                .controlSize(.small)
            }
        } else if model.workspaceSettings.repositories.isEmpty {
            HStack {
                Label("No repositories set up yet.", systemImage: "folder.badge.questionmark")
                Spacer()
                SettingsLink { Text("Add Repository…") }
            }
        } else {
            Picker("Repository", selection: $repositoryID) {
                Text("Choose…").tag(String?.none)
                ForEach(model.workspaceSettings.repositories) { repository in
                    Text("\(repository.name) (\(repository.baseBranch))").tag(Optional(repository.id))
                }
            }
            .frame(maxWidth: 420)
        }
    }

    private var effectiveRepositoryID: String? {
        detail.workspace?.repositoryID ?? repositoryID
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
                Text("Claude reads the repository in a new worktree. It cannot edit files or run commands during investigation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .investigating:
            InvestigationProgress(ticketID: ticket.id)
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
            Label("Plan v\(detail.document?.version ?? 0) approved. Implementation arrives in M4.", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        case .failed, .cancelled, .rejected:
            HStack {
                Text(state == .rejected ? "Plan rejected." : "Stopped.")
                    .foregroundStyle(.secondary)
                Button("Restart") { Task { await model.select(ticket.id) } }
            }
        case .implementing, .validating, .reviewing, .readyForHumanReview, .completeManual:
            Text("\(state.displayName).").foregroundStyle(.secondary)
        }
    }

    private func startButton(_ title: String) -> some View {
        Button(title) {
            if let id = effectiveRepositoryID { model.startInvestigation(ticket.id, repositoryID: id) }
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
        guard [.failed, .cancelled].contains(state), let run = detail.runs.last, run.outcome != .succeeded else { return nil }
        return run.errorMessage
    }
}

private struct InvestigationProgress: View {
    @Environment(AppModel.self) private var model
    let ticketID: String

    var body: some View {
        if let activity = model.activity[ticketID] {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    ProgressView().controlSize(.small)
                    TimelineView(.periodic(from: activity.startedAt, by: 1)) { context in
                        Text("Investigating… \(Duration.seconds(context.date.timeIntervalSince(activity.startedAt)).formatted(.time(pattern: .minuteSecond)))")
                            .monospacedDigit()
                    }
                    Spacer()
                    Button("Stop", role: .destructive) { model.stopInvestigation(ticketID) }
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
            Label("An investigation was in progress when DevPilot last quit. It will be marked failed on next launch.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Sections

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
