import DevPilotCore
import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(model.filteredTickets, selection: $model.selectedTicketID) { ticket in
                TicketRow(ticket: ticket, state: model.state(of: ticket.id), isUnassigned: model.unassignedIDs.contains(ticket.id))
            }
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
            if let ticket = model.selectedTicket {
                TicketDetailView(ticket: ticket)
            } else {
                ContentUnavailableView("Select a ticket", systemImage: "sidebar.left")
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
                    Task { await model.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r")
                .disabled(model.isSyncing)
            }
        }
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
