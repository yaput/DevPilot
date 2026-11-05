import AppKit
import DevPilotCore
import SwiftUI

/// The menu bar panel: what is running and what needs you, each opening its ticket.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    private static let maxRows = 6

    var body: some View {
        let running = model.tickets.filter { model.lane(of: $0.id) == .running }
        let needsYou = model.tickets.filter { model.lane(of: $0.id) == .needsYou }
        VStack(alignment: .leading, spacing: 0) {
            header(running: running.count, needsYou: needsYou.count)
            if let usage = model.claudeUsage {
                usageLine(usage)
            }
            Divider()
            if running.isEmpty && needsYou.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .font(.title)
                        .foregroundStyle(.green)
                    Text("All quiet").font(.headline)
                    Text("Nothing is running and nothing is waiting for you.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    section(.running, running)
                    section(.needsYou, needsYou)
                }
                .padding(.vertical, 10)
            }
            Divider()
            footer
        }
        .frame(width: 360)
    }

    private func header(running: Int, needsYou: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "paperplane.fill")
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text("DevPilot").font(.headline)
            Spacer()
            if running > 0 {
                Pill(text: "\(running) running", tint: .blue)
            }
            if needsYou > 0 {
                Pill(text: "\(needsYou) need\(needsYou == 1 ? "s" : "") you", tint: .orange)
            }
        }
        .padding(12)
    }

    private func usageLine(_ usage: ClaudeUsage) -> some View {
        let session = ClaudeUsage.current(usage.session)?.utilization ?? 0
        let weekly = ClaudeUsage.current(usage.weekly)?.utilization ?? 0
        return HStack(spacing: 12) {
            Label("Session \(Int((session * 100).rounded()))%", systemImage: "gauge.with.dots.needle.33percent")
            Text("Week \(Int((weekly * 100).rounded()))%")
            Spacer()
            Text(usage.updatedAt.formatted(.relative(presentation: .named)))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .help("Claude plan usage. Open the dashboard with no ticket selected for details.")
    }

    @ViewBuilder
    private func section(_ lane: TicketLane, _ tickets: [Ticket]) -> some View {
        if !tickets.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(lane.title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 2)
                ForEach(tickets.prefix(Self.maxRows)) { ticket in
                    MenuBarTicketRow(ticket: ticket) { open(ticket.id) }
                }
                if tickets.count > Self.maxRows {
                    Button("\(tickets.count - Self.maxRows) more…") { open(nil) }
                        .buttonStyle(.link)
                        .font(.caption)
                        .padding(.horizontal, 14)
                        .padding(.top, 2)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Button {
                open(nil)
            } label: {
                Label("Open Dashboard", systemImage: "macwindow")
            }
            .keyboardShortcut("d")
            Spacer()
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(model.isSyncing)
            .help("Refresh tickets")
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .help("Settings…")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .keyboardShortcut("q")
            .help("Quit DevPilot")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    /// Brings up the dashboard, showing `ticketID` when given. The panel closes as the app activates.
    private func open(_ ticketID: String?) {
        if let ticketID { model.selectedTicketID = ticketID }
        openWindow(id: AppWindow.dashboard)
        NSApp.activate()
    }
}

private struct MenuBarTicketRow: View {
    @Environment(AppModel.self) private var model
    let ticket: Ticket
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        let state = model.state(of: ticket.id)
        let activity = model.activity[ticket.id]
        let isWorking = activity != nil && activity?.queuedPosition == nil
        let isStalled = model.isStalled(ticket.id)
        Button(action: action) {
            HStack(spacing: 10) {
                StateIcon(state: state, isActive: isWorking, isStalled: isStalled, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(ticket.externalID).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text(status(state: state, activity: activity, isStalled: isStalled))
                            .font(.caption)
                            .foregroundStyle(isWorking ? .blue : isStalled ? .orange : state.tint)
                    }
                    Text(ticket.title).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 4)
                if let activity, activity.queuedPosition == nil {
                    TimelineView(.periodic(from: activity.startedAt, by: 1)) { context in
                        Text(Duration.seconds(context.date.timeIntervalSince(activity.startedAt)).formatted(.time(pattern: .minuteSecond)))
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.blue)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { isHovered = $0 }
    }

    private func status(state: WorkflowState, activity: RunActivity?, isStalled: Bool) -> String {
        if let position = activity?.queuedPosition { return "Queued #\(position)" }
        if isStalled { return state.stalledName }
        return state.displayName
    }
}
