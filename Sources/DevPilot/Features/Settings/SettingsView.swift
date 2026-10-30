import DevPilotCore
import SwiftUI

/// Settings window. Repositories and Agent tabs are filled in by M3.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(ProviderSettingsModel.self) private var form

    var body: some View {
        TabView {
            Tab("Providers", systemImage: "tray.2") {
                ProvidersSettingsView()
            }
            Tab("General", systemImage: "gearshape") {
                Form {
                    LabeledContent("Database") {
                        Text(model.databaseLocation)
                            .textSelection(.enabled)
                            .font(.callout.monospaced())
                    }
                    LabeledContent("Ticket source") {
                        Text(model.settings.useSampleData ? "Sample data" : "Shortcut / Jira")
                    }
                }
                .formStyle(.grouped)
            }
            Tab("Repositories", systemImage: "folder") {
                placeholder("Map Shortcut and Jira projects to local repositories and base branches.", milestone: "M3")
            }
            Tab("Agent", systemImage: "cpu") {
                placeholder("Codex executable, CLI login check, model, and allowed test/lint commands per repository.", milestone: "M3")
            }
        }
        .frame(width: 640, height: 640)
        .onAppear { form.reset() }
    }

    private func placeholder(_ text: String, milestone: String) -> some View {
        ContentUnavailableView {
            Label("Coming in \(milestone)", systemImage: "hammer")
        } description: {
            Text(text)
        }
    }
}

private struct ProvidersSettingsView: View {
    @Environment(ProviderSettingsModel.self) private var form

    var body: some View {
        @Bindable var form = form
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle("Use sample data instead of Shortcut and Jira", isOn: $form.draft.useSampleData)
                } footer: {
                    Text("Sample data is stored in a separate database, so it never mixes with real tickets.")
                }

                Section {
                    Toggle("Sync stories assigned to me", isOn: $form.draft.shortcut.isEnabled)
                    TextField("API URL", text: $form.draft.shortcut.apiURL, prompt: Text(ShortcutSettings.defaultAPIURL))
                    TokenField(text: $form.shortcutToken, isStored: form.hasStoredToken(.shortcut))
                    ConnectionRow(kind: .shortcut)
                } header: {
                    Text("Shortcut")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("The API token decides the workspace. Change the API URL only for a proxy.")
                        Link("How to create a Shortcut API token", destination: URL(string: "https://help.shortcut.com/hc/en-us/articles/205701199-Shortcut-API-Tokens")!)
                    }
                }
                .disabled(form.draft.useSampleData)

                Section {
                    Toggle("Sync issues assigned to me", isOn: $form.draft.jira.isEnabled)
                    TextField("Site URL", text: $form.draft.jira.siteURL, prompt: Text("https://your-company.atlassian.net"))
                    TextField("Account email", text: $form.draft.jira.email, prompt: Text("you@company.com"))
                    TokenField(text: $form.jiraToken, isStored: form.hasStoredToken(.jira))
                    TextField("Acceptance criteria field", text: $form.draft.jira.acceptanceCriteriaField, prompt: Text("customfield_10035 (optional)"))
                    ConnectionRow(kind: .jira)
                } header: {
                    Text("Jira Cloud")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Without an acceptance criteria field, DevPilot reads an \"Acceptance criteria\" heading from the description.")
                        Link("Create a Jira API token", destination: URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!)
                    }
                }
                .disabled(form.draft.useSampleData)
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if let error = form.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else {
                    Text("Tokens are stored in your Keychain. Ticket access is read-only.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Revert") { form.reset() }
                    .disabled(!form.hasChanges)
                Button("Save") { Task { await form.save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!form.hasChanges || form.isSaving)
            }
            .font(.callout)
            .padding(12)
        }
    }
}

private struct TokenField: View {
    @Binding var text: String
    let isStored: Bool

    var body: some View {
        LabeledContent {
            HStack {
                SecureField("API token", text: $text, prompt: Text(isStored ? "Saved in Keychain. Type to replace." : "Paste API token"))
                    .labelsHidden()
                if isStored && text.isEmpty {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .help("A token is saved in your Keychain")
                }
            }
        } label: {
            Text("API token")
        }
    }
}

private struct ConnectionRow: View {
    @Environment(ProviderSettingsModel.self) private var form
    let kind: TicketProviderKind

    var body: some View {
        HStack {
            Button("Test Connection") { Task { await form.testConnection(kind) } }
                .disabled(form.status[kind] == .checking)
            switch form.status[kind] ?? .idle {
            case .idle:
                EmptyView()
            case .checking:
                ProgressView().controlSize(.small)
            case .connected(let identity):
                Label(identity, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .lineLimit(1)
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .help(message)
            }
            Spacer()
            if form.hasStoredToken(kind) {
                Button("Remove Token", role: .destructive) { Task { await form.removeToken(kind) } }
            }
        }
    }
}
