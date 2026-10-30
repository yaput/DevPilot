import SwiftUI

/// Settings shell. Each tab is filled in by the milestone that needs it.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                Form {
                    LabeledContent("Database") {
                        Text(model.databaseLocation)
                            .textSelection(.enabled)
                            .font(.callout.monospaced())
                    }
                    LabeledContent("Ticket source") {
                        Text("Mock fixtures (M1)")
                    }
                }
            }
            Tab("Providers", systemImage: "tray.2") {
                placeholder("Shortcut API token and Jira Cloud URL, email and API token. Stored in Keychain.", milestone: "M2")
            }
            Tab("Repositories", systemImage: "folder") {
                placeholder("Map Shortcut projects and Jira projects to local repositories and base branches.", milestone: "M3")
            }
            Tab("Agent", systemImage: "cpu") {
                placeholder("Codex executable, CLI login check, model, and allowed test/lint commands per repository.", milestone: "M3")
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 320)
    }

    private func placeholder(_ text: String, milestone: String) -> some View {
        ContentUnavailableView {
            Label("Coming in \(milestone)", systemImage: "hammer")
        } description: {
            Text(text)
        }
    }
}
