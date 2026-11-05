import AppKit
import DevPilotCore
import SwiftUI

struct TicketDetailView: View {
    @Environment(AppModel.self) private var model
    let ticket: Ticket
    @State private var detail = TicketDetailData()
    @State private var reviewingPlan: DecisionDocument?
    @State private var tab: DetailTab = .ticket
    /// The ticket `tab` was last chosen for; another ticket gets the tab that fits its stage.
    @State private var tabTicketID: String?

    var body: some View {
        let state = model.state(of: ticket.id)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !model.isFollowing(ticket.id) {
                    Banner(message: "You stopped following this ticket. It stays hidden from your lists, autopilot and notifications.",
                           systemImage: "eye.slash", tint: .secondary) {
                        Button("Follow Again") { Task { await model.setFollowing(true, ticketIDs: [ticket.id]) } }
                            .controlSize(.small)
                    }
                }
                header(state: state)
                PipelineStepper(
                    state: state, lastRunKind: detail.runs.last?.kind, isRunning: model.isRunning(ticket.id),
                    // Reproduced QA bugs count against the Test stage too.
                    testsPassed: detail.latestValidation?.validation.map {
                        ($0.commands.isEmpty || $0.passed) && (detail.latestQA?.qa?.confirmedCount ?? 0) == 0
                    },
                    reviewApproved: detail.latestReview?.review.map { $0.verdict == .approve }
                )
                    .padding(.vertical, 4)
                WorkflowPanel(ticket: ticket, state: state, detail: detail) { reviewingPlan = $0 }
                if let workspace = detail.workspace, FileManager.default.fileExists(atPath: workspace.worktreePath) {
                    WorkspaceBar(ticket: ticket, workspace: workspace, hasImplementation: detail.latestImplementation != nil)
                    TryLocallyCard(ticket: ticket, workspace: workspace)
                }
                tabs
            }
            .padding(28)
            .frame(maxWidth: 940, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: "\(ticket.id)|\(state.rawValue)|\(model.detailRevision)") {
            detail = await model.loadDetail(ticket.id)
            if tabTicketID != ticket.id {
                tabTicketID = ticket.id
                tab = DetailTab.preferred(for: state)
            }
            if !availableTabs.contains(tab) { tab = .ticket }
        }
        .sheet(item: $reviewingPlan) { document in
            ApprovalSheet(ticket: ticket, document: document)
        }
    }

    private func header(state: WorkflowState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProviderBadge(provider: ticket.provider)
                Text(ticket.externalID).font(.callout.monospaced()).foregroundStyle(.secondary)
                    .help(ticket.source)
                Label {
                    Text(ticket.type.displayName).foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: ticket.type.symbol).foregroundStyle(ticket.type.tint)
                }
                .font(.caption.weight(.medium))
                Text(ticket.status)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.6), in: Capsule())
                Spacer()
                StateBadge(state: state, isStalled: model.isStalled(ticket.id))
            }
            Text(ticket.title)
                .font(.title.weight(.bold))
                .textSelection(.enabled)
            HStack(spacing: 16) {
                if ticket.provider == .local {
                    Label("Created in DevPilot \(ticket.fetchedAt.formatted(.relative(presentation: .named)))", systemImage: "square.and.pencil")
                        .foregroundStyle(.secondary)
                } else {
                    Link(destination: ticket.url) {
                        Label("Open in \(ticket.provider.displayName)", systemImage: "arrow.up.right.square")
                    }
                    Text("Fetched \(ticket.fetchedAt.formatted(.relative(presentation: .named)))")
                        .foregroundStyle(.secondary)
                }
                if model.unassignedIDs.contains(ticket.id) {
                    Label("No longer assigned to you", systemImage: "person.crop.circle.badge.questionmark")
                        .foregroundStyle(.orange)
                }
            }
            .font(.callout)
        }
    }

    // MARK: Tabs

    private var availableTabs: [DetailTab] {
        DetailTab.allCases.filter { tab in
            switch tab {
            case .ticket, .history: true
            case .plan: detail.document != nil
            case .implementation: detail.latestImplementation?.implementation != nil
            case .verification: detail.latestValidation != nil || detail.latestReview != nil
            }
        }
    }

    private var tabs: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Section", selection: $tab) {
                ForEach(availableTabs, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, 6)
            switch tab {
            case .ticket:
                TicketContentSection(ticket: ticket)
            case .plan:
                if let document = detail.document {
                    DecisionRecordSection(document: document, artifacts: model.artifacts)
                }
            case .implementation:
                if let run = detail.latestImplementation, let result = run.implementation {
                    ImplementationSection(run: run, result: result)
                }
            case .verification:
                VerificationSection(ticket: ticket, detail: detail)
            case .history:
                HistorySection(events: detail.events, runs: detail.runs)
            }
        }
    }
}

private enum DetailTab: CaseIterable {
    case ticket, plan, implementation, verification, history

    var title: String {
        switch self {
        case .ticket: "Ticket"
        case .plan: "Plan"
        case .implementation: "Implementation"
        case .verification: "Tests & Review"
        case .history: "History"
        }
    }

    /// What the user most likely wants to read at this stage.
    static func preferred(for state: WorkflowState) -> DetailTab {
        switch state {
        case .needsClarification, .planReady, .awaitingPlanApproval, .approved, .needsRevision: .plan
        case .implementing: .implementation
        case .validating, .reviewing, .readyForHumanReview, .completeManual: .verification
        default: .ticket
        }
    }
}

// MARK: - Pipeline

/// Investigate → Plan → Implement → Test → Review → Hand-off, with where the ticket is now.
private struct PipelineStepper: View {
    let state: WorkflowState
    let lastRunKind: AgentRun.Kind?
    let isRunning: Bool
    /// Latest results; a stage passed with problems shows a warning instead of a check.
    let testsPassed: Bool?
    let reviewApproved: Bool?

    enum Status { case done, warning, active, attention, failed, stopped, upcoming }

    private static let stages: [(title: String, symbol: String)] = [
        ("Investigate", "magnifyingglass"), ("Plan", "doc.text"), ("Implement", "hammer"),
        ("Test", "testtube.2"), ("Review", "eye"), ("Hand-off", "person.crop.circle.badge.checkmark"),
    ]

    /// The current stage and how it stands; stages before it are done.
    private var position: (index: Int, status: Status) {
        switch state {
        case .discovered, .selected: (0, .upcoming)
        case .investigating: (0, .active)
        case .needsClarification, .needsRevision: (0, .attention)
        case .planReady, .awaitingPlanApproval: (1, .attention)
        case .rejected: (1, .failed)
        case .approved: (2, .upcoming)
        case .implementing: (2, .active)
        case .validating: (3, isRunning ? .active : .attention)
        case .reviewing: (4, isRunning ? .active : .attention)
        case .readyForHumanReview: (5, .attention)
        case .completeManual: (Self.stages.count, .done)
        case .failed, .cancelled:
            (Self.stageIndex(of: lastRunKind), state == .failed ? .failed : .stopped)
        }
    }

    private static func stageIndex(of kind: AgentRun.Kind?) -> Int {
        switch kind {
        case .implementation?: 2
        case .validation?, .qa?: 3
        case .review?: 4
        case .investigation?, nil: 0
        }
    }

    private func status(at index: Int) -> Status {
        let (current, status) = position
        guard index < current else { return index == current ? status : .upcoming }
        if index == 3 && testsPassed == false { return .warning }
        if index == 4 && reviewApproved == false { return .warning }
        return .done
    }

    private func isPast(_ status: Status) -> Bool { status == .done || status == .warning }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Self.stages.indices, id: \.self) { index in
                if index > 0 {
                    Capsule()
                        .fill(isPast(status(at: index - 1)) ? AnyShapeStyle(Color.green.opacity(0.6)) : AnyShapeStyle(.quaternary))
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 14)
                }
                let stage = Self.stages[index]
                VStack(spacing: 6) {
                    node(status(at: index), symbol: stage.symbol)
                        .help(help(index))
                    Text(stage.title)
                        .font(.caption.weight(status(at: index) == .upcoming ? .regular : .semibold))
                        .foregroundStyle(status(at: index) == .upcoming ? .secondary : .primary)
                        .fixedSize()
                }
                .frame(width: 68)
            }
        }
    }

    private func help(_ index: Int) -> String {
        switch (index, status(at: index)) {
        case (3, .warning): "Tests ran with failures"
        case (4, .warning): "The review requested changes"
        default: ""
        }
    }

    @ViewBuilder
    private func node(_ status: Status, symbol: String) -> some View {
        let (fill, icon): (Color?, String) = switch status {
        case .done: (.green, "checkmark")
        case .warning: (.orange, "exclamationmark")
        case .active: (.blue, symbol)
        case .attention: (.orange, symbol)
        case .failed: (.red, "xmark")
        case .stopped: (.gray, "stop.fill")
        case .upcoming: (nil, symbol)
        }
        ZStack {
            if let fill {
                Circle().fill(fill.gradient)
                    .shadow(color: fill.opacity(0.35), radius: status == .active ? 6 : 2)
            } else {
                Circle().strokeBorder(.quaternary, lineWidth: 1.5)
            }
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(fill == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.white))
                .symbolEffect(.pulse, isActive: status == .active)
        }
        .frame(width: 30, height: 30)
    }
}

// MARK: - Workflow panel

/// The "what can I do now" card: repository choice, investigation progress, clarification
/// answers and the entry point to plan review. Rarely used and destructive actions live in its menu.
private struct WorkflowPanel: View {
    @Environment(AppModel.self) private var model
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
    @State private var deletingTicketIDs: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("NEXT STEP")
                        .font(.caption2.weight(.semibold))
                        .tracking(0.8)
                        .foregroundStyle(.secondary)
                    Text(headline)
                        .font(.title3.weight(.semibold))
                }
                Spacer()
                moreMenu
            }
            if detail.workspace == nil {
                repositoryPicker
            }
            if let error = lastRunError {
                if detail.runs.last?.outcome == .cancelled {
                    Banner("You stopped the last run.", systemImage: "stop.circle.fill", tint: .secondary)
                } else {
                    Banner(error)
                }
            }
            stateContent
        }
        .card(padding: 18)
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12, style: .continuous)
                .fill(accent.gradient)
                .frame(width: 4)
        }
        .confirmationDialog("Start \(ticket.externalID) over?", isPresented: $confirmingStartOver) {
            Button("Start Over", role: .destructive) { Task { await model.startOver(ticket.id) } }
        } message: {
            Text(startOverMessage)
        }
        .confirmationDialog("Discard this worktree?", isPresented: $confirmingDiscard) {
            Button("Discard Worktree", role: .destructive) { Task { await model.discardWorktree(ticket.id) } }
        } message: {
            if let workspace = detail.workspace {
                Text("""
                    Removes \(workspace.worktreePath). Git refuses if it has uncommitted changes, so nothing \
                    unsaved can be lost. Branch \(workspace.branch) is deleted only if it has no commits of its own. \
                    The next investigation creates a new worktree from the repository's current base branch.
                    """)
            }
        }
        .deleteTicketsConfirmation($deletingTicketIDs)
        .onAppear { repositoryID = repositoryID ?? model.workspaceSettings.suggestedRepository(for: ticket)?.id }
        .onChange(of: ticket.id) {
            repositoryID = model.workspaceSettings.suggestedRepository(for: ticket)?.id
            answers = ""
        }
    }

    private var isQueued: Bool { model.activity[ticket.id]?.queuedPosition != nil }

    private var accent: Color {
        if isQueued { return .secondary }
        return model.isRunning(ticket.id) ? .blue : state.tint
    }

    private var headline: String {
        if isQueued { return "Queued" }
        let plan = "Plan v\(detail.document?.version ?? 1)"
        let running = model.isRunning(ticket.id)
        return switch state {
        case .discovered: "Pick this ticket up"
        case .selected: "Ready to investigate"
        case .needsRevision: "Revision requested"
        case .investigating: "Investigating"
        case .needsClarification: "Claude has questions"
        case .planReady, .awaitingPlanApproval: "\(plan) is ready for your approval"
        case .approved: "\(plan) approved, ready to implement"
        case .implementing: "Implementing"
        case .validating: running ? "Running tests" : detail.latestValidation == nil ? "Implemented, tests haven't run" : "Tests need to run again"
        case .reviewing: running ? "Reviewing" : "Review didn't finish"
        case .readyForHumanReview: "Ready for your review"
        case .completeManual: "Done"
        case .failed: "Run failed"
        case .cancelled: "Stopped"
        case .rejected: "Plan rejected"
        }
    }

    // MARK: More menu

    @ViewBuilder
    private var moreMenu: some View {
        let busy = state.isAgentRunning || model.isRunning(ticket.id)
        let canCancel = state.canTransition(to: .cancelled)
        // Always has an item: Delete for DevPilot tickets, Stop Following for synced ones.
        Menu {
            if canStartOver {
                Button {
                    Task {
                        startOverStatus = await model.branchStatus(ticket.id)
                        confirmingStartOver = true
                    }
                } label: {
                    Label("Start Over…", systemImage: "arrow.counterclockwise")
                }
                .help("Back to the start with a fresh worktree, no earlier plans or answers, and transcripts deleted.")
            }
            if detail.workspace != nil {
                Button(role: .destructive) { confirmingDiscard = true } label: {
                    Label("Discard Worktree…", systemImage: "trash")
                }
                .disabled(busy)
            }
            if canCancel {
                Divider()
                Button(role: .destructive) { Task { await model.cancel(ticket.id) } } label: {
                    Label("Cancel Ticket", systemImage: "xmark.circle")
                }
            }
            if ticket.provider == .local {
                Divider()
                Button(role: .destructive) { deletingTicketIDs = [ticket.id] } label: {
                    Label("Delete Ticket…", systemImage: "trash")
                }
                .disabled(busy)
            } else {
                Divider()
                if model.isFollowing(ticket.id) {
                    Button { Task { await model.setFollowing(false, ticketIDs: [ticket.id]) } } label: {
                        Label("Stop Following", systemImage: "eye.slash")
                    }
                    .disabled(busy)
                    .help("Hides the ticket from your lists, autopilot and notifications, even while it is assigned to you.")
                } else {
                    Button { Task { await model.setFollowing(true, ticketIDs: [ticket.id]) } } label: {
                        Label("Follow Again", systemImage: "eye")
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
    }

    // MARK: Repository

    @ViewBuilder
    private var repositoryPicker: some View {
        if model.workspaceSettings.repositories.isEmpty {
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
        if isQueued {
            // Waiting for a free slot; the ticket has not moved yet.
            RunProgress(ticketID: ticket.id)
        } else {
            stateSpecificContent
        }
    }

    @ViewBuilder
    private var stateSpecificContent: some View {
        switch state {
        case .discovered:
            Button("Select for Investigation") { Task { await model.select(ticket.id) } }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        case .selected, .needsRevision:
            VStack(alignment: .leading, spacing: 10) {
                if state == .needsRevision {
                    Text("The next investigation gets your notes and the previous plan.")
                        .foregroundStyle(.secondary)
                }
                startButton(state == .needsRevision ? "Re-investigate" : "Start Investigation")
                Text(investigationCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .investigating, .implementing:
            RunProgress(ticketID: ticket.id)
        // `where` binds only to the last pattern, so each state needs its own.
        case .validating where model.isRunning(ticket.id), .reviewing where model.isRunning(ticket.id):
            RunProgress(ticketID: ticket.id)
        case .needsClarification:
            clarificationForm
        case .planReady, .awaitingPlanApproval:
            if let document = detail.document {
                Button {
                    reviewPlan(document)
                } label: {
                    Label("Review Plan v\(document.version)…", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        case .approved:
            implementForm
        case .validating, .reviewing:
            // Resting here: verification was interrupted, failed to start, or predates M5.
            VStack(alignment: .leading, spacing: 10) {
                Text(state == .reviewing ? "Tests ran; the review did not finish."
                     : detail.latestValidation == nil ? "The implementation is done, but tests and review have not run yet."
                     : "The results below are from an earlier run and may be out of date.")
                    .foregroundStyle(.secondary)
                if let id = effectiveRepositoryID {
                    Button {
                        model.startVerification(ticket.id, repositoryID: id)
                    } label: {
                        Label(state == .validating ? "Run Tests & Review" : "Run Review", systemImage: "checklist")
                    }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            }
        case .readyForHumanReview:
            if let id = effectiveRepositoryID {
                HandoffPanel(ticket: ticket, detail: detail, repositoryID: id)
            }
        case .completeManual:
            DonePanel(ticketID: ticket.id, hasWorktree: detail.workspace != nil)
        case .failed, .cancelled, .rejected:
            HStack {
                if canRetryImplementation, let id = effectiveRepositoryID {
                    if let session = detail.runs.last?.sessionID {
                        Button {
                            Task { await model.continueImplementation(ticket.id, repositoryID: id, sessionID: session) }
                        } label: {
                            Label("Continue Implementation", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .help("Resumes the same Claude session where it stopped, with everything it already read and changed.")
                        Button {
                            Task { await model.retryImplementation(ticket.id, repositoryID: id) }
                        } label: {
                            Label("New Session", systemImage: "arrow.clockwise")
                        }
                        .help("A fresh Claude session implements the approved plan, building on the changes already in the worktree.")
                    } else {
                        Button {
                            Task { await model.retryImplementation(ticket.id, repositoryID: id) }
                        } label: {
                            Label("Retry Implementation", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent)
                        .help("A fresh Claude session implements the approved plan, building on the changes already in the worktree.")
                    }
                }
                Button("Restart from Investigation") { Task { await model.select(ticket.id) } }
            }
            .controlSize(.large)
        }
    }

    /// The last run was an implementation of a plan that is still approved.
    private var canRetryImplementation: Bool {
        state != .rejected && detail.runs.last?.kind == .implementation && detail.document != nil
    }

    private var implementForm: some View {
        let repository = effectiveRepositoryID.flatMap(model.workspaceSettings.repository(id:))
        let setup = repository?.setupCommands.filter(\.isEnabled).map { $0.command + ($0.isOptional ? " (optional)" : "") } ?? []
        let commands = repository?.agentCommands.filter(\.isEnabled).map(\.command) ?? []
        return VStack(alignment: .leading, spacing: 10) {
            if let repository {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Setup: " + (setup.isEmpty ? "none" : setup.joined(separator: "; ")), systemImage: "shippingbox")
                    Label("Claude may run: " + (commands.isEmpty ? "no commands (file edits only)" : commands.joined(separator: ", ")), systemImage: "terminal")
                    Label("Edits stay in this worktree. No commits, no pushes, no network.", systemImage: "lock.shield")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack {
                    Button {
                        model.startImplementation(ticket.id, repositoryID: repository.id)
                    } label: {
                        Label("Implement", systemImage: "hammer")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.isRunning(ticket.id))
                    SettingsLink { Text("Edit Commands…") }
                }
            } else {
                Banner("This ticket's repository was removed from Settings. Add it again to implement.", tint: .orange)
            }
        }
    }

    private func startButton(_ title: String) -> some View {
        Button {
            if let id = effectiveRepositoryID { model.startInvestigation(ticket.id, repositoryID: id, baseBranch: baseBranch) }
        } label: {
            Label(title, systemImage: "magnifyingglass")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(effectiveRepositoryID == nil || model.isRunning(ticket.id))
    }

    private var clarificationForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Implementation is blocked until these questions are answered.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array((detail.document?.investigation?.clarifyingQuestions ?? []).enumerated()), id: \.offset) { index, question in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1)")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(Color.orange.gradient, in: Circle())
                        Text(question).textSelection(.enabled)
                    }
                }
            }
            TextEditor(text: $answers)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 90)
                .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))
            Text("Answer here, or update the ticket in \(ticket.provider.displayName) and refresh, then re-investigate.")
                .font(.caption)
                .foregroundStyle(.secondary)
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

    var body: some View {
        if let activity = model.activity[ticketID], let position = activity.queuedPosition {
            HStack {
                Image(systemName: "hourglass").symbolEffect(.pulse)
                Text("#\(position) in line: Claude is already working on as many tickets as Settings → Agent allows.")
                Spacer()
                Button("Cancel", role: .destructive) { model.stopRun(ticketID) }
            }
            .foregroundStyle(.secondary)
        } else if let activity = model.activity[ticketID] {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    TimelineView(.periodic(from: activity.startedAt, by: 1)) { context in
                        Text(Duration.seconds(context.date.timeIntervalSince(activity.startedAt)).formatted(.time(pattern: .minuteSecond)))
                            .font(.callout.weight(.medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) { model.stopRun(ticketID) } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                }
                if !activity.lines.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(activity.lines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.caption.monospaced())
                                .foregroundStyle(index == activity.lines.count - 1 ? .primary : .secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator.opacity(0.6)))
                }
            }
        } else {
            // Running according to the database but not in this session: the app was restarted.
            Banner("A run was in progress when DevPilot last quit. It will be stopped and marked failed on next launch.", tint: .orange)
        }
    }
}

// MARK: - Workspace

/// The ticket's worktree in one line, with ways to open it.
private struct WorkspaceBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let ticket: Ticket
    let workspace: TicketWorkspace
    let hasImplementation: Bool

    @State private var status: BranchStatus?
    @State private var isCommitting = false
    @State private var lastCommit: String?
    @State private var showingMessage = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(model.workspaceSettings.repository(id: workspace.repositoryID)?.name ?? "Worktree")
                        .font(.callout.weight(.semibold))
                    if hasImplementation, let status {
                        Text(summary(status))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("\(workspace.branch) ← \(workspace.baseBranch) @ \(workspace.baseCommit.prefix(8))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .help(workspace.worktreePath)
            Spacer()
            // Investigation only reads; there is nothing to show before an implementation.
            if hasImplementation {
                commitButton
                Button { openWindow(id: AppWindow.changes, value: ticket.id) } label: {
                    Label("View Changes", systemImage: "plusminus")
                }
            }
            OpenWorktreeMenu(workspace: workspace)
                .fixedSize()
            Menu {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: workspace.worktreePath)])
                }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(workspace.worktreePath, forType: .string)
                }
            } label: {
                Image(systemName: "folder")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Worktree folder")
        }
        .controlSize(.small)
        .card(padding: 12)
        .task(id: "\(model.detailRevision)|\(model.isRunning(ticket.id))|\(model.state(of: ticket.id))") { await loadStatus() }
        // Back from the editor or Terminal: the worktree may have changed.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await loadStatus() }
        }
    }

    /// One click commits everything on the ticket's branch as `SC-1234: Title`; the arrow
    /// offers a custom message and skipping hooks.
    @ViewBuilder
    private var commitButton: some View {
        let files = status?.uncommittedFiles ?? 0
        if isCommitting {
            ProgressView().controlSize(.small)
                .help("Committing. Commit hooks may take a moment.")
        } else if files > 0 {
            let blocker = model.commitBlocker(ticket.id)
            Menu {
                Button("Commit with Message…") { showingMessage = true }
            } label: {
                Label("Commit \(files) File\(files == 1 ? "" : "s")", systemImage: "checkmark.circle")
            } primaryAction: {
                commit(message: nil, skippingHooks: false)
            }
            .fixedSize()
            .disabled(blocker != nil)
            .help(blocker ?? "Commits all \(files) changed file\(files == 1 ? "" : "s") on \(workspace.branch) as “\(model.defaultCommitMessage(ticket.id))”. Nothing is pushed.")
            .popover(isPresented: $showingMessage, arrowEdge: .bottom) {
                CommitMessageForm(initial: model.defaultCommitMessage(ticket.id), branch: workspace.branch) { message, skippingHooks in
                    showingMessage = false
                    commit(message: message, skippingHooks: skippingHooks)
                }
            }
        } else if let lastCommit {
            Label("Committed \(lastCommit)", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
                .help("Committed on \(workspace.branch). Push it from Terminal or your editor.")
        }
    }

    private func summary(_ status: BranchStatus) -> String {
        var parts: [String] = []
        if status.commitsSinceBase > 0 {
            parts.append("\(status.commitsSinceBase) commit\(status.commitsSinceBase == 1 ? "" : "s")"
                         + (status.upstream != nil && status.unpushedCommits == 0 ? ", pushed" : ", not pushed"))
        }
        if let files = status.uncommittedFiles, files > 0 {
            parts.append("\(files) uncommitted")
        }
        return parts.joined(separator: " · ")
    }

    private func commit(message: String?, skippingHooks: Bool) {
        isCommitting = true
        Task {
            if let hash = await model.commitChanges(ticket.id, message: message, skippingHooks: skippingHooks) {
                lastCommit = hash
            }
            await loadStatus()
            isCommitting = false
        }
    }

    private func loadStatus() async {
        guard hasImplementation else { return }
        status = await model.branchStatus(ticket.id)
    }
}

/// The commit message, editable, and whether to skip the repository's commit hooks.
private struct CommitMessageForm: View {
    let branch: String
    let onCommit: (String, Bool) -> Void
    @State private var message: String
    @State private var skippingHooks = false

    init(initial: String, branch: String, onCommit: @escaping (String, Bool) -> Void) {
        self.branch = branch
        self.onCommit = onCommit
        _message = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Commit on \(branch)").font(.headline)
            TextField("Message", text: $message, axis: .vertical)
                .lineLimit(3...8)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
            Toggle("Skip commit hooks (--no-verify)", isOn: $skippingHooks)
                .help("For when a hook fails only because it expects something DevPilot cannot provide. Tests already ran in DevPilot.")
            HStack {
                Text("All changed files are staged. Nothing is pushed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Commit") { onCommit(message, skippingHooks) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}

/// Run Locally and QA. One line until there is something to show: a local run of this ticket,
/// or a QA session running or finished.
private struct TryLocallyCard: View {
    @Environment(AppModel.self) private var model
    let ticket: Ticket
    let workspace: TicketWorkspace

    var body: some View {
        let expanded = model.localRun?.ticketID == ticket.id || model.qaSession?.ticketID == ticket.id
            || !model.qaSessions(ticketID: ticket.id).isEmpty
        Group {
            if expanded {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader("Try It Locally", systemImage: "play.rectangle")
                    LocalRunPanel(ticket: ticket, workspace: workspace)
                    Divider()
                    QASessionPanel(ticket: ticket, workspace: workspace)
                }
                .card()
            } else {
                compact.card(padding: 12)
            }
        }
        .animation(.snappy, value: expanded)
    }

    private var compact: some View {
        let configured = model.workspaceSettings.repository(id: workspace.repositoryID)?.localRun.isConfigured == true
        let otherRunActive = model.localRun.map { run in
            switch run.phase {
            case .failed, .stopped: false
            default: true
            }
        } ?? false
        return HStack(spacing: 10) {
            Image(systemName: "play.rectangle")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text("Try It Locally").font(.callout.weight(.semibold))
                Text(model.pipelineQATicketID != nil ? "DevPilot is testing another ticket locally (pipeline QA)."
                     : otherRunActive ? "The app is running locally for another ticket."
                     : configured ? "Runs the app from this worktree on its own ports and a database copy, then QA can test it."
                     : "Needs this repository's services set up first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            if model.pipelineQATicketID != nil {
                EmptyView()
            } else if otherRunActive {
                Button("Stop It") { Task { await model.stopLocalRun() } }
            } else if configured {
                Button {
                    model.startLocalRun(ticketID: ticket.id, workspace: workspace)
                } label: {
                    Label("Run Locally", systemImage: "play.fill")
                }
            } else {
                SettingsLink { Text("Configure…") }
            }
        }
        .controlSize(.small)
    }
}

// MARK: - Sections

private struct ImplementationSection: View {
    @Environment(\.openWindow) private var openWindow
    let run: AgentRun
    let result: ImplementationResult

    var body: some View {
        let report = result.report
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Implementation of plan v\(result.planVersion)", systemImage: "hammer") {
                Pill(text: report.outcome.rawValue.capitalized, tint: report.outcome == .completed ? .green : .orange)
                Button("View Changes") { openWindow(id: AppWindow.changes, value: run.ticketID) }
                    .controlSize(.small)
                Button("Transcript") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: run.logPath)]) }
                    .controlSize(.small)
            }
            MarkdownView(markdown: report.summary)
            group("Changed files (\(result.changedFiles.count))") {
                ForEach(result.changedFiles, id: \.self) { file in
                    HStack(spacing: 8) {
                        Text(file.change.rawValue)
                            .font(.caption2.weight(.semibold).monospaced())
                            .foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .leading)
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
        .card()
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
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}

private struct DecisionRecordSection: View {
    let document: DecisionDocument
    let artifacts: ArtifactStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Decision record v\(document.version)", systemImage: "doc.text") {
                Text(document.contentHash.prefix(12))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .help("SHA-256 of this exact text. Approval is bound to it.")
                Button("Show File") {
                    let url = artifacts.decisionURL(for: document)
                    if !FileManager.default.fileExists(atPath: url.path) { try? artifacts.write(document) }
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .controlSize(.small)
            }
            Divider()
            MarkdownView(markdown: document.markdown)
        }
        .card(padding: 20)
    }
}

private struct TicketContentSection: View {
    let ticket: Ticket

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            section("Description", systemImage: "text.alignleft") {
                if ticket.description.isEmpty {
                    Text("No description.").foregroundStyle(.secondary)
                } else {
                    MarkdownView(markdown: ticket.description)
                }
            }
            section("Acceptance criteria", systemImage: "checklist") {
                if ticket.acceptanceCriteria.isEmpty {
                    Text("None found.").foregroundStyle(.secondary)
                }
                ForEach(ticket.acceptanceCriteria, id: \.self) { criterion in
                    Label {
                        Text(criterion).textSelection(.enabled)
                    } icon: {
                        Image(systemName: "checkmark.circle").foregroundStyle(.green)
                    }
                }
            }
            if !ticket.comments.isEmpty {
                section("Comments", systemImage: "bubble.left.and.bubble.right") {
                    ForEach(ticket.comments, id: \.self) { comment in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Image(systemName: "person.circle.fill").foregroundStyle(.secondary)
                                Text(comment.author).font(.caption.weight(.semibold))
                                Text(comment.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            MarkdownView(markdown: comment.body)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
        }
        .card(padding: 20)
    }

    private func section<Content: View>(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title, systemImage: systemImage)
            content()
        }
    }
}

/// Workflow events and agent runs in one timeline, newest first.
private struct HistorySection: View {
    let events: [WorkflowEvent]
    let runs: [AgentRun]

    private enum Entry: Identifiable {
        case event(WorkflowEvent)
        case run(AgentRun)

        var id: String {
            switch self {
            case .event(let event): "event-\(event.id)"
            case .run(let run): "run-\(run.id)"
            }
        }

        var date: Date {
            switch self {
            case .event(let event): event.createdAt
            case .run(let run): run.startedAt
            }
        }
    }

    var body: some View {
        let entries = (events.map(Entry.event) + runs.map(Entry.run)).sorted { $0.date > $1.date }
        VStack(alignment: .leading, spacing: 0) {
            if entries.isEmpty {
                Text("Nothing has happened yet.").foregroundStyle(.secondary)
            }
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        Circle()
                            .fill(tint(entry).gradient)
                            .frame(width: 9, height: 9)
                            .padding(.top, 6)
                        if index < entries.count - 1 {
                            Rectangle()
                                .fill(.quaternary)
                                .frame(width: 1.5)
                                .frame(maxHeight: .infinity)
                        }
                    }
                    .frame(width: 12)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            title(entry)
                            Spacer()
                            Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .help(entry.date.formatted(date: .complete, time: .standard))
                        }
                        detail(entry)
                    }
                    .padding(.bottom, 16)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card(padding: 20)
    }

    private func tint(_ entry: Entry) -> Color {
        switch entry {
        case .event(let event): event.toState?.tint ?? .secondary
        case .run(let run): run.outcome?.tint ?? .blue
        }
    }

    @ViewBuilder
    private func title(_ entry: Entry) -> some View {
        switch entry {
        case .event(let event):
            if let to = event.toState {
                StateBadge(state: to)
            } else if event.kind == .clarification {
                Label("Answers", systemImage: "text.bubble").font(.callout.weight(.semibold))
            } else {
                Text(event.kind.rawValue.capitalized).font(.callout.weight(.semibold))
            }
        case .run(let run):
            HStack(spacing: 8) {
                Label("\(run.kind.displayName) run", systemImage: run.kind.symbol).font(.callout.weight(.semibold))
                Pill(text: run.outcome?.displayName ?? "Running", tint: run.outcome?.tint ?? .blue)
            }
        }
    }

    @ViewBuilder
    private func detail(_ entry: Entry) -> some View {
        switch entry {
        case .event(let event):
            if !event.message.isEmpty {
                Text(event.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
        case .run(let run):
            HStack(spacing: 10) {
                if let finished = run.finishedAt {
                    Label(Duration.seconds(finished.timeIntervalSince(run.startedAt)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)),
                          systemImage: "clock")
                }
                if let turns = run.numTurns {
                    Label("\(turns) turns", systemImage: "arrow.triangle.2.circlepath")
                }
                Button("Transcript") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: run.logPath)])
                }
                .controlSize(.mini)
                .disabled(!FileManager.default.fileExists(atPath: run.logPath))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let message = run.errorMessage, run.outcome != .succeeded {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
    }
}
