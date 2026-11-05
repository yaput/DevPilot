import DevPilotCore
import SwiftUI

/// The toolbar's usage gauge: the session percentage at a glance, the full card on click.
struct UsageToolbarButton: View {
    @Environment(AppModel.self) private var model
    @State private var showing = false

    var body: some View {
        let session = model.claudeUsage.flatMap { ClaudeUsage.current($0.session) }
        Button {
            showing.toggle()
        } label: {
            Label {
                Text(session.map { "\(Int(($0.utilization * 100).rounded()))%" } ?? "Usage")
            } icon: {
                Image(systemName: "gauge.with.dots.needle.50percent")
            }
            .labelStyle(.titleAndIcon)
        }
        .help("Claude usage")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            UsageCard(compact: true)
                .frame(width: 300)
                .padding(12)
        }
    }
}

/// The detail area with no ticket selected: Claude plan usage, so `/usage` needs no terminal.
struct HomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Claude usage").font(.title.weight(.bold))
                    Text("Your claude.ai plan, shared by DevPilot and the Claude Code CLI.")
                        .foregroundStyle(.secondary)
                }
                UsageCard()
                Label("Select a ticket on the left to work on it. ⌘-click or ⇧-click to select several.", systemImage: "sidebar.left")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The plan's session and weekly usage. `compact` fits a side column or a popover.
struct UsageCard: View {
    @Environment(AppModel.self) private var model
    var compact = false

    var body: some View {
        // Redraws every half minute so reset countdowns and "updated" stay current.
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            let now = Date()
            let usage = model.claudeUsage
            VStack(alignment: .leading, spacing: compact ? 14 : 18) {
                if compact {
                    Label("Claude usage", systemImage: "gauge.with.dots.needle.50percent").font(.headline)
                }
                UsageMeter(
                    title: "Current session", detail: "5-hour window", window: usage?.session, now: now,
                    hasReading: usage != nil, resetStyle: .time, compact: compact
                )
                Divider()
                UsageMeter(
                    title: "This week", detail: "All models, 7-day window", window: usage?.weekly, now: now,
                    hasReading: usage != nil, resetStyle: .dayAndTime, compact: compact
                )
                if usage?.isUsingOverage == true {
                    Banner("You are past your plan's limits and using extra usage.", systemImage: "creditcard", tint: .orange)
                }
                if let error = model.usageError {
                    Banner(error)
                }
                footer(usage, now: now)
            }
            .card(padding: compact ? 16 : 20)
        }
        .task { await model.refreshUsageIfStale() }
    }

    private func footer(_ usage: ClaudeUsage?, now: Date) -> some View {
        HStack(spacing: 8) {
            if let usage {
                Text("Updated \(usage.updatedAt.formatted(.relative(presentation: .named, unitsStyle: compact ? .abbreviated : .wide)))")
                    .help(usage.updatedAt.formatted(date: .abbreviated, time: .standard))
            } else {
                Text("No reading yet.")
            }
            Spacer()
            if model.isFetchingUsage {
                ProgressView().controlSize(.small)
            }
            Button {
                Task { await model.refreshUsage() }
            } label: {
                if compact {
                    Image(systemName: "arrow.clockwise")
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .disabled(model.isFetchingUsage)
            .help("Sends one tiny request to Claude Haiku and reads the usage it reports. Runs in DevPilot update it on their own.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .controlSize(.small)
    }
}

private struct UsageMeter: View {
    enum ResetStyle { case time, dayAndTime }

    let title: String
    let detail: String
    let window: ClaudeUsage.Window?
    let now: Date
    let hasReading: Bool
    let resetStyle: ResetStyle
    var compact = false

    var body: some View {
        // A window whose reset has passed starts again from zero.
        let current = ClaudeUsage.current(window, now: now)
        let fraction = min(max(current?.utilization ?? 0, 0), 1)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(compact ? .subheadline.weight(.semibold) : .headline)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(hasReading ? "\(Int((fraction * 100).rounded()))%" : "–")
                    .font((compact ? Font.title3 : .title2).weight(.semibold).monospacedDigit())
                    .foregroundStyle(tint(current))
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(tint(current).gradient)
                        .frame(width: max(fraction > 0 ? 6 : 0, proxy.size.width * fraction))
                }
            }
            .frame(height: 8)
            Text(resetText(current))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func tint(_ window: ClaudeUsage.Window?) -> Color {
        guard let window else { return .accentColor }
        if window.status == "rejected" || window.utilization >= 0.9 { return .red }
        if window.status == "allowed_warning" || window.utilization >= 0.7 { return .orange }
        return .accentColor
    }

    private func resetText(_ window: ClaudeUsage.Window?) -> String {
        guard hasReading else { return "Refresh to read your usage." }
        guard let window else { return "Reset since the last reading; it starts again with your next use." }
        let when = switch resetStyle {
        case .time: window.resetsAt.formatted(date: .omitted, time: .shortened)
        case .dayAndTime: window.resetsAt.formatted(.dateTime.weekday(.wide).hour().minute())
        }
        let remaining = Duration.seconds(window.resetsAt.timeIntervalSince(now))
            .formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
        let limit = window.status == "rejected" ? "Limit reached. " : ""
        return "\(limit)Resets \(when) (in \(remaining))"
    }
}
