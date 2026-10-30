import DevPilotCore
import SwiftUI

struct TicketDetailView: View {
    @Environment(AppModel.self) private var model
    let ticket: Ticket
    @State private var events: [WorkflowEvent] = []

    var body: some View {
        let state = model.state(of: ticket.id)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header(state: state)
                actions(state: state)
                section("Description") {
                    Text(ticket.description.isEmpty ? "No description." : ticket.description)
                        .textSelection(.enabled)
                }
                section("Acceptance criteria") {
                    if ticket.acceptanceCriteria.isEmpty {
                        Text("None provided.").foregroundStyle(.secondary)
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
                                Text(comment.body).textSelection(.enabled)
                            }
                        }
                    }
                }
                section("History") {
                    ForEach(events) { event in
                        HStack(alignment: .firstTextBaseline) {
                            Text(event.createdAt.formatted(date: .abbreviated, time: .standard))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 170, alignment: .leading)
                            if let to = event.toState {
                                StateBadge(state: to)
                            }
                            Text(event.message)
                                .font(.callout)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: "\(ticket.id)|\(state.rawValue)") {
            events = await model.events(for: ticket.id)
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

    @ViewBuilder
    private func actions(state: WorkflowState) -> some View {
        HStack {
            if state.canTransition(to: .selected) {
                Button("Select for Investigation") { Task { await model.select(ticket.id) } }
                    .buttonStyle(.borderedProminent)
            }
            if state.canTransition(to: .cancelled) {
                Button("Cancel", role: .destructive) { Task { await model.cancel(ticket.id) } }
            }
            if state == .selected {
                Text("Investigation with Codex arrives in M3.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
