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

struct StateBadge: View {
    let state: WorkflowState

    var body: some View {
        Label(state.displayName, systemImage: state.symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(state.tint)
    }
}

extension TicketProviderKind {
    var tint: Color {
        switch self {
        case .shortcut: .purple
        case .jira: .blue
        }
    }
}

extension WorkflowState {
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
