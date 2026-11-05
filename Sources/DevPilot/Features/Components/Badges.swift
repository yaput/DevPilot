import DevPilotCore
import SwiftUI

struct ProviderBadge: View {
    let provider: TicketProviderKind

    var body: some View {
        Text(provider.displayName)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(provider.tint)
            .background(provider.tint.opacity(0.15), in: Capsule())
    }
}

/// The workflow state as a tinted pill.
struct StateBadge: View {
    let state: WorkflowState
    /// See `WorkflowState.isStalledWhenIdle`.
    var isStalled = false

    var body: some View {
        let tint = isStalled ? Color.orange : state.tint
        Label(isStalled ? state.stalledName : state.displayName, systemImage: state.symbol)
            .font(.caption.weight(.medium))
            .labelStyle(PillLabelStyle())
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.13), in: Capsule())
            .fixedSize()
    }
}

/// The state's symbol in a tinted rounded square; pulses while an agent works on the ticket.
struct StateIcon: View {
    let state: WorkflowState
    var isActive = false
    var isStalled = false
    var size: CGFloat = 28

    var body: some View {
        let tint = isActive ? Color.blue : isStalled ? .orange : state.tint
        Image(systemName: isActive ? "sparkles" : state.symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(tint)
            .symbolEffect(.pulse, isActive: isActive)
            .frame(width: size, height: size)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
    }
}

private struct PillLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// A small capsule label, e.g. an outcome or verdict.
struct Pill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

// MARK: - Cards and banners

extension View {
    /// The standard grouped surface of the detail view.
    func card(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }
}

/// A section title with an optional trailing accessory.
struct SectionHeader<Accessory: View>: View {
    let title: String
    var systemImage: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
            Spacer()
            accessory
        }
        .font(.headline)
    }
}

extension SectionHeader where Accessory == EmptyView {
    init(_ title: String, systemImage: String? = nil) {
        self.init(title: title, systemImage: systemImage) { EmptyView() }
    }
}

/// A tinted message strip: run errors inside a card, or app-wide messages above the content.
struct Banner<Actions: View>: View {
    let message: String
    var systemImage = "exclamationmark.triangle.fill"
    var tint: Color = .red
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.25)))
    }
}

extension Banner where Actions == EmptyView {
    init(_ message: String, systemImage: String = "exclamationmark.triangle.fill", tint: Color = .red) {
        self.init(message: message, systemImage: systemImage, tint: tint) { EmptyView() }
    }
}

// MARK: - Display helpers

extension TicketProviderKind {
    var tint: Color {
        switch self {
        case .shortcut: .purple
        case .jira: .blue
        case .local: .teal
        }
    }
}

extension TicketType {
    var symbol: String {
        switch self {
        case .feature: "star"
        case .bug: "ladybug"
        case .chore: "wrench.and.screwdriver"
        }
    }

    var tint: Color {
        switch self {
        case .feature: .yellow
        case .bug: .red
        case .chore: .gray
        }
    }
}

extension AgentRun.Kind {
    var displayName: String {
        switch self {
        case .investigation: "Investigation"
        case .implementation: "Implementation"
        case .validation: "Tests"
        case .review: "Review"
        case .qa: "QA session"
        }
    }

    var symbol: String {
        switch self {
        case .investigation: "magnifyingglass"
        case .implementation: "hammer"
        case .validation: "testtube.2"
        case .review: "eye"
        case .qa: "ladybug"
        }
    }
}

extension AgentRun.Outcome {
    var displayName: String {
        switch self {
        case .succeeded: "Succeeded"
        case .failed: "Failed"
        case .cancelled: "Stopped"
        case .timedOut: "Timed out"
        case .interrupted: "Interrupted"
        }
    }

    var tint: Color {
        switch self {
        case .succeeded: .green
        case .cancelled: .gray
        case .failed, .timedOut, .interrupted: .red
        }
    }
}

extension WorkflowState {
    /// Validating and reviewing are also resting states: with no run in progress, verification
    /// was interrupted or never started, and the ticket waits for the user.
    var isStalledWhenIdle: Bool { self == .validating || self == .reviewing }

    var stalledName: String {
        self == .validating ? "Tests not run" : "Review unfinished"
    }

    var tint: Color {
        switch self {
        case .discovered, .selected: .secondary
        case .investigating, .implementing, .validating, .reviewing: .blue
        case .needsClarification, .needsRevision, .awaitingPlanApproval, .planReady: .orange
        case .approved, .readyForHumanReview, .completeManual: .green
        case .failed, .rejected: .red
        case .cancelled: .gray
        }
    }

    var symbol: String {
        switch self {
        case .discovered: "tray"
        case .selected: "hand.point.up"
        case .investigating: "magnifyingglass"
        case .needsClarification: "questionmark.bubble"
        case .planReady, .awaitingPlanApproval: "doc.badge.clock"
        case .needsRevision: "arrow.uturn.backward"
        case .approved: "checkmark.seal"
        case .implementing: "hammer"
        case .validating: "testtube.2"
        case .reviewing: "eye"
        case .readyForHumanReview: "person.crop.circle.badge.checkmark"
        case .completeManual: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle"
        case .cancelled: "xmark.circle"
        case .rejected: "hand.thumbsdown"
        }
    }
}
