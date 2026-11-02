import DevPilotCore
import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @State private var creatingTicket = false
    @State private var confirmingBulk: BulkAction?
    @State private var bulkTicketIDs: [String] = []

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(model.filteredTickets, selection: $model.selection) { ticket in
                TicketRow(
                    ticket: ticket, state: model.state(of: ticket.id), isUnassigned: model.unassignedIDs.contains(ticket.id),
                    activity: model.activity[ticket.id]
                )
            }
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
            }
            .bulkConfirmation($confirmingBulk, ticketIDs: bulkTicketIDs)
            .overlay {
                if !model.hasProviders {
                    ContentUnavailableView {
                        Label("No ticket sources", systemImage: "link")
                    } description: {
                        Text("Connect Shortcut or Jira, or turn on sample data.")
                    } actions: {
                        SettingsLink { Text("Open Settings…") }
                    }
                } else if model.filteredTickets.isEmpty && !model.isSyncing {
                    ContentUnavailableView("No assigned tickets", systemImage: "tray", description: Text("Refresh to sync."))
                }
            }
            .safeAreaInset(edge: .bottom) { SyncStatusView() }
            .navigationSplitViewColumnWidth(min: 300, ideal: 380)
        } detail: {
            if model.selection.count > 1 {
                BatchPanel(ticketIDs: Array(model.selection))
            } else if let ticket = model.selectedTicket {
                TicketDetailView(ticket: ticket)
            } else {
                ContentUnavailableView("Select a ticket", systemImage: "sidebar.left",
                                       description: Text("⌘-click or ⇧-click to select several and investigate them together."))
            }
        }
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
        .alert("DevPilot", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.lastError ?? "")
        }
    }
}

private struct TicketRow: View {
    let ticket: Ticket
    let state: WorkflowState
    let isUnassigned: Bool
    let activity: RunActivity?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                ProviderBadge(provider: ticket.provider)
                Text(ticket.externalID)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .help(ticket.source)
                if isUnassigned {
                    Text("Not assigned")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help("No longer returned by \(ticket.provider.displayName); kept because work on it is in progress.")
                }
                Spacer()
                if let position = activity?.queuedPosition {
                    Text("Queued #\(position)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else if activity != nil {
                    ProgressView().controlSize(.mini)
                }
                StateBadge(state: state)
            }
            Text(ticket.title)
                .lineLimit(2)
            Text(ticket.status)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct SyncStatusView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.isSyncing {
                ProgressView().controlSize(.small)
            }
            ForEach(model.providerKinds, id: \.self) { kind in
                Text(line(for: kind))
                    .font(.caption2)
                    .foregroundStyle(isFailure(kind) ? .red : .secondary)
                    .lineLimit(1)
                    .help(line(for: kind))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.bar)
    }

    private func isFailure(_ kind: TicketProviderKind) -> Bool {
        if case .failed = model.syncResults[kind]?.outcome { return true }
        return false
    }

    private func line(for kind: TicketProviderKind) -> String {
        guard let result = model.syncResults[kind] else { return "\(kind.displayName): not synced yet" }
        let time = result.finishedAt.formatted(date: .omitted, time: .shortened)
        switch result.outcome {
        case .synced(let count): return "\(kind.displayName): \(count) tickets · \(time)"
        case .failed(let message): return "\(kind.displayName): failed at \(time) – \(message)"
        }
    }
}

/// Several tickets selected: act on all of them at once. Each action applies to the tickets at
/// the right stage; the rest are skipped and listed with the reason.
private struct BatchPanel: View {
    @Environment(AppModel.self) private var model
    let ticketIDs: [String]
    @State private var skipped: [(ticket: Ticket, reason: String)] = []
    @State private var confirming: BulkAction?

    var body: some View {
        let tickets = model.tickets.filter { ticketIDs.contains($0.id) }
        VStack(alignment: .leading, spacing: 16) {
            Text("\(tickets.count) tickets selected").font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                ForEach(tickets) { ticket in
                    HStack(spacing: 8) {
                        ProviderBadge(provider: ticket.provider)
                        Text(ticket.externalID).font(.callout.monospaced()).foregroundStyle(.secondary)
                        Text(ticket.title).lineLimit(1)
                        Spacer()
                        if let repository = model.workspaceSettings.suggestedRepository(for: ticket) {
                            Text(repository.name).font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("no repository").font(.caption).foregroundStyle(.orange)
                        }
                        if model.isRunning(ticket.id) { ProgressView().controlSize(.mini) }
                        StateBadge(state: model.state(of: ticket.id))
                    }
                }
            }
            FlowButtons(ticketIDs: ticketIDs, confirming: $confirming, skipped: $skipped)
            Text("""
                Investigations run up to \(model.agentSettings.maxParallelInvestigations) at once, and implementation, \
                tests and review up to \(model.agentSettings.maxParallelBuilds); the rest wait in a queue (Settings → Agent). \
                Each ticket uses its own worktree and branch.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(skipped, id: \.ticket.id) { item in
                Label("\(item.ticket.externalID) skipped: \(item.reason)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
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
        let available = BulkAction.allCases.map { ($0, model.eligible($0, among: ticketIDs).count) }
        HStack {
            ForEach(available.filter { $0.1 > 0 }, id: \.0) { action, count in
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
            if available.allSatisfy({ $0.1 == 0 }) {
                Text("No action applies to all of these right now. Open a ticket to continue it.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

extension View {
    /// Asks before approving plans the user has not opened.
    func bulkConfirmation(
        _ action: Binding<BulkAction?>, ticketIDs: [String], onDone: @escaping ([(ticket: Ticket, reason: String)]) -> Void = { _ in }
    ) -> some View {
        modifier(BulkConfirmation(action: action, ticketIDs: ticketIDs, onDone: onDone))
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
