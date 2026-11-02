import DevPilotCore
import SwiftUI

/// Writes a ticket in DevPilot itself: for trying the workflow on a repository, or for work
/// that has no Shortcut or Jira ticket. It goes through the same investigate → implement → QA flow.
struct NewTicketSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var type = TicketType.feature
    @State private var repositoryID: String?
    @State private var description = ""
    @State private var criteria = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Title", text: $title, prompt: Text("What should change?"))
                Picker("Type", selection: $type) {
                    Text("Feature").tag(TicketType.feature)
                    Text("Bug").tag(TicketType.bug)
                    Text("Chore").tag(TicketType.chore)
                }
                .pickerStyle(.segmented)
                Picker("Repository", selection: $repositoryID) {
                    Text("Choose…").tag(String?.none)
                    ForEach(model.workspaceSettings.repositories) { repository in
                        Text(repository.name).tag(Optional(repository.id))
                    }
                }
                Section("Description") {
                    TextEditor(text: $description).font(.body).frame(minHeight: 140)
                }
                Section {
                    TextEditor(text: $criteria).font(.body).frame(minHeight: 80)
                } header: {
                    Text("Acceptance criteria")
                } footer: {
                    Text("One per line. The plan, the review and the QA agent check the change against these.")
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Text("Branches are named like \(type == .bug ? "fix" : type == .chore ? "chore" : "feat")/DP-1.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Create Ticket") {
                    let lines = criteria.split(whereSeparator: \.isNewline)
                        .map { $0.trimmingCharacters(in: .whitespaces).trimmingPrefix(/[-*•]\s*/) }
                        .map(String.init).filter { !$0.isEmpty }
                    let repository = repositoryID
                    Task {
                        await model.createLocalTicket(
                            title: title.trimmingCharacters(in: .whitespaces), description: description,
                            acceptanceCriteria: lines, type: type, repositoryID: repository ?? ""
                        )
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || repositoryID == nil)
            }
            .padding(12)
        }
        .frame(width: 620, height: 600)
        .onAppear {
            if model.workspaceSettings.repositories.count == 1 { repositoryID = model.workspaceSettings.repositories[0].id }
        }
    }
}
