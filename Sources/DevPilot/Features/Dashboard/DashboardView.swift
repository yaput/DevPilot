import DevPilotCore
import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var creatingTicket = false
    @State private var confirmingBulk: BulkAction?
    @State private var bulkTicketIDs: [String] = []
    @State private var searchText = ""
    @State private var deletingTicketIDs: [String] = []
    @State private var showsDone = false
    @State private var showsUnfollowed = false

    var body: some View {
        @Bindable var model = model
        let tickets = visibleTickets
        NavigationSplitView {
            List(selection: $model.selection) {
                ForEach(TicketLane.allCases.filter { $0 != .done }, id: \.self) { lane in
                    let rows = sorted(tickets.filter { model.lane(of: $0.id) == lane })
                    if !rows.isEmpty {
                        Section {
                            ForEach(rows) { row($0) }
                        } header: {
                            LaneHeader(lane: lane, count: rows.count)
                        }
                    }
                }
                let done = tickets.filter { model.lane(of: $0.id) == .done }
                if !done.isEmpty {
                    Section(isExpanded: $showsDone) {
                        ForEach(done) { row($0) }
                    } header: {
                        LaneHeader(lane: .done, count: done.count)
                    }
                }
                let unfollowed = filtered(model.unfollowedTickets)
                if !unfollowed.isEmpty {
                    Section(isExpanded: $showsUnfollowed) {
                        ForEach(unfollowed) { row($0).opacity(0.6) }
                    } header: {
                        HStack(spacing: 6) {
                            Image(systemName: "eye.slash").font(.caption2)
                            Text("Not Following")
                            Text("\(unfollowed.count)")
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                        .help("Synced tickets you stopped following. They stay hidden through syncs; right-click to follow one again.")
                    }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $searchText, placement: .sidebar, prompt: "Search tickets")
            .contextMenu(forSelectionType: String.self) { ids in
                let ticketIDs = Array(ids)
                ForEach(BulkAction.allCases, id: \.self) { action in
                    let count = model.eligible(action, among: ticketIDs).count
                    if count > 0 {
                        Button {
                            if action.needsConfirmation {
                                bulkTicketIDs = ticketIDs
                                confirmingBulk = action
                            } else {
                                Task { await model.perform(action, on: ticketIDs) }
                            }
                        } label: {
                            Label(ticketIDs.count > 1 ? "\(action.title) (\(count))" : action.title, systemImage: action.systemImage)
                        }
                    }
                }
                let unfollowable = model.unfollowableTickets(among: ticketIDs)
                let refollowable = model.unfollowedTickets.filter { ticketIDs.contains($0.id) }
                if !unfollowable.isEmpty || !refollowable.isEmpty {
                    Divider()
                }
                if !unfollowable.isEmpty {
                    Button {
                        Task { await model.setFollowing(false, ticketIDs: unfollowable.map(\.id)) }
                    } label: {
                        Label(unfollowable.count > 1 ? "Stop Following \(unfollowable.count) Tickets" : "Stop Following", systemImage: "eye.slash")
                    }
                }
                if !refollowable.isEmpty {
                    Button {
                        Task { await model.setFollowing(true, ticketIDs: refollowable.map(\.id)) }
                    } label: {
                        Label(refollowable.count > 1 ? "Follow \(refollowable.count) Tickets Again" : "Follow Again", systemImage: "eye")
                    }
                }
                let deletable = model.deletableTickets(among: ticketIDs)
                if !deletable.isEmpty {
                    Divider()
                    Button(role: .destructive) {
                        deletingTicketIDs = deletable.map(\.id)
                    } label: {
                        Label(deletable.count > 1 ? "Delete \(deletable.count) DevPilot Tickets…" : "Delete Ticket…", systemImage: "trash")
                    }
                }
            }
            .bulkConfirmation($confirmingBulk, ticketIDs: bulkTicketIDs)
            .deleteTicketsConfirmation($deletingTicketIDs)
            .overlay {
                if !model.hasProviders {
                    ContentUnavailableView {
                        Label("No ticket sources", systemImage: "link")
                    } description: {
                        Text("Connect Shortcut or Jira, or turn on sample data.")
                    } actions: {
                        SettingsLink { Text("Open Settings…") }
                    }
                } else if tickets.isEmpty && !searchText.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else if tickets.isEmpty && !model.isSyncing {
                    ContentUnavailableView("No assigned tickets", systemImage: "tray", description: Text("Refresh to sync."))
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { SidebarFooter() }
            .navigationSplitViewColumnWidth(min: 300, ideal: 360)
        } detail: {
            // With room to spare beside a ticket, the usage card fills the right-hand side.
            GeometryReader { proxy in
                HStack(alignment: .top, spacing: 0) {
                    Group {
                        if model.selection.count > 1 {
                            BatchPanel(ticketIDs: Array(model.selection))
                        } else if let ticket = model.selectedTicket {
                            TicketDetailView(ticket: ticket)
                        } else {
                            HomeView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if !model.selection.isEmpty && proxy.size.width >= Self.sideUsageMinWidth {
                        ScrollView {
                            UsageCard(compact: true)
                                .padding(.top, 28)
                                .padding(.trailing, 24)
                        }
                        .frame(width: 300)
                        .scrollIndicators(.never)
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { MessageBanner() }
        }
        .navigationTitle("DevPilot")
        .navigationSubtitle(summary)
        .toolbar {
            ToolbarItem {
                Picker("Provider", selection: $model.providerFilter) {
                    Text("All").tag(TicketProviderKind?.none)
                    ForEach(model.providerKinds, id: \.self) { kind in
                        Text(kind.displayName).tag(Optional(kind))
                    }
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem {
                UsageToolbarButton()
            }
            ToolbarItem {
                Button {
                    creatingTicket = true
                } label: {
                    Label("New Ticket", systemImage: "square.and.pencil")
                }
                .help("Write a ticket in DevPilot, without a tracker")
                .keyboardShortcut("n")
                .disabled(model.workspaceSettings.repositories.isEmpty)
            }
            ToolbarItem {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r")
                .disabled(model.isSyncing)
            }
        }
        .sheet(isPresented: $creatingTicket) { NewTicketSheet() }
        .onAppear {
            IsolatedCapture.openWindow = openWindow
            IsolatedCapture.openSettings = openSettings
        }
    }

    /// A ticket stays readable (about 760 points) next to the 300-point usage column.
    static let sideUsageMinWidth: CGFloat = 1_060

    private var visibleTickets: [Ticket] {
        filtered(model.filteredTickets)
    }

    /// The search and provider filter, applied to any ticket list.
    private func filtered(_ tickets: [Ticket]) -> [Ticket] {
        let byProvider = model.providerFilter.map { kind in tickets.filter { $0.provider == kind } } ?? tickets
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return byProvider }
        return byProvider.filter {
            $0.externalID.localizedCaseInsensitiveContains(query) || $0.title.localizedCaseInsensitiveContains(query)
        }
    }

    /// Working runs first, then the queue in order.
    private func sorted(_ tickets: [Ticket]) -> [Ticket] {
        tickets.enumerated().sorted { lhs, rhs in
            let left = model.activity[lhs.element.id]?.queuedPosition ?? 0
            let right = model.activity[rhs.element.id]?.queuedPosition ?? 0
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }

    private func row(_ ticket: Ticket) -> some View {
        TicketRow(
            ticket: ticket, state: model.state(of: ticket.id), isUnassigned: model.unassignedIDs.contains(ticket.id),
            activity: model.activity[ticket.id]
        )
    }

    private var summary: String {
        let lanes = model.tickets.map { model.lane(of: $0.id) }
        let needsYou = lanes.filter { $0 == .needsYou }.count
        let running = lanes.filter { $0 == .running }.count
        var parts: [String] = []
        if needsYou > 0 { parts.append("\(needsYou) need\(needsYou == 1 ? "s" : "") you") }
        if running > 0 { parts.append("\(running) running") }
        if AppDatabase.isIsolated { parts.insert("Isolated copy", at: 0) }
        return parts.isEmpty ? "All quiet" : parts.joined(separator: " · ")
    }
}

// MARK: - Lanes

/// Sidebar grouping by what a ticket needs from the user.
enum TicketLane: CaseIterable {
    case needsYou, running, toDo, done

    var title: String {
        switch self {
        case .needsYou: "Needs You"
        case .running: "Running"
        case .toDo: "To Do"
        case .done: "Done"
        }
    }

    var tint: Color {
        switch self {
        case .needsYou: .orange
        case .running: .blue
        case .toDo: .secondary
        case .done: .green
        }
    }
}

extension AppModel {
    func lane(of ticketID: String) -> TicketLane {
        let state = state(of: ticketID)
        if activity[ticketID] != nil || state.isAgentRunning { return .running }
        switch state {
        // Validating/reviewing at rest means verification was interrupted and needs a restart.
        case .needsClarification, .planReady, .awaitingPlanApproval, .readyForHumanReview, .failed, .validating, .reviewing:
            return .needsYou
        case .completeManual, .cancelled, .rejected:
            return .done
        default:
            return .toDo
        }
    }

    /// Validating or reviewing with nothing running: verification was interrupted and waits for the user.
    func isStalled(_ ticketID: String) -> Bool {
        activity[ticketID] == nil && state(of: ticketID).isStalledWhenIdle
    }

    /// Runs holding an agent slot (not queued).
    var agentsWorking: Int {
        activity.values.filter { $0.queuedPosition == nil }.count
    }
}

private struct LaneHeader: View {
    let lane: TicketLane
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(lane.tint).frame(width: 6, height: 6)
            Text(lane.title)
            Text("\(count)")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
        }
    }
}

// MARK: - Rows

private struct TicketRow: View {
    let ticket: Ticket
    let state: WorkflowState
    let isUnassigned: Bool
    let activity: RunActivity?

    private var isWorking: Bool { activity != nil && activity?.queuedPosition == nil }
    private var isStalled: Bool { activity == nil && state.isStalledWhenIdle }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StateIcon(state: state, isActive: isWorking, isStalled: isStalled)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Circle().fill(ticket.provider.tint).frame(width: 6, height: 6)
                        .help(ticket.provider.displayName)
                    Text(ticket.externalID)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .help(ticket.source)
                    if isUnassigned {
                        Image(systemName: "person.crop.circle.badge.questionmark")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .help("No longer returned by \(ticket.provider.displayName); kept because work on it is in progress.")
                    }
                    Spacer(minLength: 4)
                    trailing
                }
                Text(ticket.title)
                    .fontWeight(.medium)
                    .lineLimit(2)
                subtitle
            }
        }
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private var trailing: some View {
        if let activity, let position = activity.queuedPosition {
            Text("Queued #\(position)")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
        } else if let activity {
            TimelineView(.periodic(from: activity.startedAt, by: 1)) { context in
                Text(Duration.seconds(context.date.timeIntervalSince(activity.startedAt)).formatted(.time(pattern: .minuteSecond)))
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.blue)
            }
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        if let activity, activity.queuedPosition != nil {
            Text("Waiting for a free agent slot")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let activity {
            Text(activity.lines.last.map { "› \($0)" } ?? "\(state.displayName)…")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        } else {
            HStack(spacing: 4) {
                Text(isStalled ? state.stalledName : state.displayName).foregroundStyle(isStalled ? .orange : state.tint)
                Text("·").foregroundStyle(.tertiary)
                Text(ticket.status).foregroundStyle(.secondary)
            }
            .font(.caption)
            .lineLimit(1)
        }
    }
}

// MARK: - Footer

private struct SidebarFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                SlotMeter(title: "Agents", used: model.agentsWorking, limit: model.agentSettings.maxParallelAgents)
                SlotMeter(title: "Builds", used: model.buildsRunning, limit: model.agentSettings.maxParallelBuilds)
                Spacer(minLength: 0)
                if model.isSyncing {
                    ProgressView().controlSize(.mini)
                }
            }
            .help("Tickets Claude is working on, and build or test commands running now (Settings → Agent).")
            SyncIndicator()
            ForEach(model.providerKinds.filter { $0 != .local }, id: \.self) { kind in
                HStack(spacing: 6) {
                    Circle().fill(color(for: kind)).frame(width: 6, height: 6)
                    Text(line(for: kind))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .help(line(for: kind))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func color(for kind: TicketProviderKind) -> Color {
        switch model.syncResults[kind]?.outcome {
        case .synced?: .green
        case .failed?: .red
        case nil: .secondary
        }
    }

    private func line(for kind: TicketProviderKind) -> String {
        guard let result = model.syncResults[kind] else { return "\(kind.displayName): not synced yet" }
        let time = result.finishedAt.formatted(date: .omitted, time: .shortened)
        switch result.outcome {
        case .synced(let count): return "\(kind.displayName) · \(count) ticket\(count == 1 ? "" : "s") · \(time)"
        case .failed(let message): return "\(kind.displayName) failed at \(time): \(message)"
        }
    }
}

/// Autopilot state and when the next background sync is due.
private struct SyncIndicator: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let autopilot = model.autopilotInvestigates || model.autopilotImplements
        HStack(spacing: 6) {
            if autopilot {
                Label("Autopilot on", systemImage: "airplane")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.green.opacity(0.14), in: Capsule())
                    .help(autopilotHelp)
            }
            if model.syncsProviders {
                // The tick only redraws; its date can lag the clock, so the text reads the clock.
                TimelineView(.periodic(from: .now, by: 15)) { _ in
                    Text(syncText(now: Date()))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    private func syncText(now: Date) -> String {
        if model.isSyncing { return "Syncing…" }
        guard let next = model.nextSyncAt, let interval = model.syncIntervalMinutes else {
            return "Background sync off (Settings → Providers)"
        }
        let seconds = next.timeIntervalSince(now)
        let when = seconds < 60 ? "in under a minute" : "in \(min(interval, Int((seconds / 60).rounded(.up)))) min"
        return "Next sync \(when) · every \(interval) min"
    }

    private var autopilotHelp: String {
        model.workspaceSettings.repositories.compactMap { repository in
            var parts: [String] = []
            if repository.autopilot.investigatesNewTickets { parts.append("investigates new tickets") }
            if repository.autopilot.implementWhenApproved { parts.append("implements approved plans") }
            return parts.isEmpty ? nil : "\(repository.name): \(parts.joined(separator: ", "))"
        }.joined(separator: "\n")
    }
}

private struct SlotMeter: View {
    let title: String
    let used: Int
    let limit: Int

    var body: some View {
        HStack(spacing: 5) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 2) {
                ForEach(0..<max(limit, used), id: \.self) { index in
                    Capsule()
                        .fill(index < used ? AnyShapeStyle(Color.blue) : AnyShapeStyle(.quaternary))
                        .frame(width: 9, height: 5)
                }
            }
            Text("\(used)/\(limit)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Messages

/// App-wide messages (sync, settings, run failures) as a dismissible strip instead of a modal alert.
private struct MessageBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 6) {
            // Newest first.
            ForEach(model.messages.reversed()) { message in
                Banner(message: message.text, tint: .orange) {
                    Text(message.date.formatted(date: .omitted, time: .shortened))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button {
                        model.dismissMessage(message.id)
                    } label: {
                        Image(systemName: "xmark").font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
                }
                .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            if model.messages.count > 1 {
                Button("Dismiss All") { model.lastError = nil }
                    .buttonStyle(.link)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, model.messages.isEmpty ? 0 : 10)
        .animation(.snappy, value: model.messages)
    }
}

// MARK: - Batch

/// Several tickets selected: act on all of them at once. Each action applies to the tickets at
/// the right stage; the rest are skipped and listed with the reason.
private struct BatchPanel: View {
    @Environment(AppModel.self) private var model
    let ticketIDs: [String]
    @State private var skipped: [(ticket: Ticket, reason: String)] = []
    @State private var confirming: BulkAction?

    var body: some View {
        let tickets = model.tickets.filter { ticketIDs.contains($0.id) }
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(tickets.count) tickets selected").font(.title2.weight(.bold))
                    Text("Each ticket uses its own worktree and branch.").foregroundStyle(.secondary)
                }
                VStack(spacing: 0) {
                    ForEach(Array(tickets.enumerated()), id: \.element.id) { index, ticket in
                        if index > 0 { Divider() }
                        HStack(spacing: 10) {
                            StateIcon(state: model.state(of: ticket.id), isActive: model.isRunning(ticket.id),
                                      isStalled: model.isStalled(ticket.id), size: 24)
                            Text(ticket.externalID).font(.callout.monospaced()).foregroundStyle(.secondary)
                            Text(ticket.title).lineLimit(1)
                            Spacer()
                            if let repository = model.workspaceSettings.suggestedRepository(for: ticket) {
                                Label(repository.name, systemImage: "folder").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Label("No repository", systemImage: "folder.badge.questionmark").font(.caption).foregroundStyle(.orange)
                            }
                            StateBadge(state: model.state(of: ticket.id), isStalled: model.isStalled(ticket.id))
                        }
                        .padding(.vertical, 8)
                    }
                }
                .card(padding: 12)
                FlowButtons(ticketIDs: ticketIDs, confirming: $confirming, skipped: $skipped)
                Text("""
                    Claude works on up to \(model.agentSettings.maxParallelAgents) tickets at once, with up to \
                    \(model.agentSettings.maxParallelBuilds) builds or test runs between them; the rest wait in a queue (Settings → Agent).
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(skipped, id: \.ticket.id) { item in
                    Banner("\(item.ticket.externalID) skipped: \(item.reason)", tint: .orange)
                }
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: ticketIDs) { skipped = [] }
        .bulkConfirmation($confirming, ticketIDs: ticketIDs) { skipped = $0 }
    }
}

/// One button per bulk action, with how many selected tickets it applies to.
private struct FlowButtons: View {
    @Environment(AppModel.self) private var model
    let ticketIDs: [String]
    @Binding var confirming: BulkAction?
    @Binding var skipped: [(ticket: Ticket, reason: String)]

    var body: some View {
        let available = BulkAction.allCases.map { ($0, model.eligible($0, among: ticketIDs).count) }.filter { $0.1 > 0 }
        HStack {
            ForEach(available, id: \.0) { action, count in
                // The first applicable action is the natural next step.
                if action == available.first?.0 {
                    button(action, count).buttonStyle(.borderedProminent)
                } else {
                    button(action, count)
                }
            }
            if available.isEmpty {
                Text("No action applies to all of these right now. Open a ticket to continue it.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func button(_ action: BulkAction, _ count: Int) -> some View {
        Button {
            if action.needsConfirmation {
                confirming = action
            } else {
                Task { skipped = await model.perform(action, on: ticketIDs) }
            }
        } label: {
            Label("\(action.title) (\(count))", systemImage: action.systemImage)
        }
        .controlSize(.large)
    }
}

extension View {
    /// Asks before deleting DevPilot tickets, and whether their worktrees go too.
    func deleteTicketsConfirmation(_ ticketIDs: Binding<[String]>) -> some View {
        modifier(DeleteTicketsConfirmation(ticketIDs: ticketIDs))
    }

    /// Asks before approving plans the user has not opened.
    func bulkConfirmation(
        _ action: Binding<BulkAction?>, ticketIDs: [String], onDone: @escaping ([(ticket: Ticket, reason: String)]) -> Void = { _ in }
    ) -> some View {
        modifier(BulkConfirmation(action: action, ticketIDs: ticketIDs, onDone: onDone))
    }
}

private struct DeleteTicketsConfirmation: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var ticketIDs: [String]

    func body(content: Content) -> some View {
        let tickets = model.deletableTickets(among: ticketIDs)
        let names = tickets.map(\.externalID).joined(separator: ", ")
        content.confirmationDialog(
            tickets.count == 1 ? "Delete \(names)?" : "Delete \(tickets.count) DevPilot tickets?",
            isPresented: Binding(get: { !ticketIDs.isEmpty }, set: { if !$0 { ticketIDs = [] } })
        ) {
            let ids = ticketIDs
            Button("Delete, Keep Worktrees") { Task { await model.deleteLocalTickets(ids, removingWorktrees: false) } }
            Button("Delete with Worktrees", role: .destructive) { Task { await model.deleteLocalTickets(ids, removingWorktrees: true) } }
        } message: {
            Text("""
                \(tickets.count == 1 ? "" : names + ": ")plans, runs, history and logs are deleted. This cannot be undone. \
                Deleting worktrees also deletes any uncommitted changes in them; branches with commits are kept.
                """)
        }
    }
}

private struct BulkConfirmation: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var action: BulkAction?
    let ticketIDs: [String]
    let onDone: ([(ticket: Ticket, reason: String)]) -> Void

    func body(content: Content) -> some View {
        let count = action.map { model.eligible($0, among: ticketIDs).count } ?? 0
        content.confirmationDialog(
            "Approve \(count) plan\(count == 1 ? "" : "s") without opening them?",
            isPresented: Binding(get: { action != nil }, set: { if !$0 { action = nil } })
        ) {
            if let action {
                Button(action == .approveAndImplement ? "Approve and Implement" : "Approve") {
                    Task { onDone(await model.perform(action, on: ticketIDs)) }
                }
            }
        } message: {
            Text("Each latest plan is approved as it is now. Implementation follows only that approved plan.")
        }
    }
}
