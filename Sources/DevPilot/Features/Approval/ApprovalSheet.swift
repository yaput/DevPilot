import DevPilotCore
import SwiftUI

/// Approve, request revision or reject one exact plan version. The decision is bound to the
/// SHA-256 of the text shown here.
struct ApprovalSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let ticket: Ticket
    let document: DecisionDocument

    @State private var notes = ""
    @State private var confirmingReject = false
    @State private var isSubmitting = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Review plan v\(document.version)").font(.title3.weight(.semibold))
                Text("\(ticket.externalID): \(ticket.title)").foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)

            Divider()
            ScrollView {
                MarkdownView(markdown: document.markdown).padding(20)
            }

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Notes").font(.headline)
                TextEditor(text: $notes)
                    .frame(height: 70)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                Text("Required when requesting a revision; they are passed to the next investigation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("Plan hash \(document.contentHash.prefix(12))")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Reject…", role: .destructive) { confirmingReject = true }
                    Button("Request Revision") { submit(.revisionRequested) }
                        .disabled(trimmedNotes.isEmpty)
                    Button("Approve Plan") { submit(.approved) }
                        .buttonStyle(.borderedProminent)
                }
                .disabled(isSubmitting)
            }
            .padding(16)
        }
        .frame(width: 760, height: 720)
        .confirmationDialog("Reject this plan?", isPresented: $confirmingReject) {
            Button("Reject Plan", role: .destructive) { submit(.rejected) }
        } message: {
            Text("The ticket stops here. You can restart it later from the ticket screen.")
        }
    }

    private var trimmedNotes: String {
        notes.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit(_ decision: ApprovalDecision) {
        isSubmitting = true
        Task {
            await model.decide(ticket.id, decision: decision, planHash: document.contentHash, notes: trimmedNotes)
            dismiss()
        }
    }
}
