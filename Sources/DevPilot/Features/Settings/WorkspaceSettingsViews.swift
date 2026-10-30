import AppKit
import DevPilotCore
import SwiftUI

/// Repositories, routing rules and the worktree folder. Changes apply immediately.
struct RepositoriesSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = WorkspaceSettings()
    @State private var error: String?
    @State private var isAdding = false

    var body: some View {
        Form {
            Section {
                if draft.repositories.isEmpty {
                    Text("No repositories yet.").foregroundStyle(.secondary)
                }
                ForEach($draft.repositories) { $repository in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            TextField("Name", text: $repository.name).font(.headline)
                            Button(role: .destructive) { remove(repository.id) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .help("Remove repository (existing worktrees are kept)")
                        }
                        Text(repository.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        TextField("Base branch", text: $repository.baseBranch, prompt: Text("main"))
                    }
                    .padding(.vertical, 2)
                }
                HStack {
                    Button("Add Repository…") { addRepository() }
                        .disabled(isAdding)
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).lineLimit(2)
                    }
                }
            } header: {
                Text("Repositories")
            } footer: {
                Text("New ticket worktrees branch from the base branch as it is locally. DevPilot never fetches, commits or pushes.")
            }

            Section {
                ForEach($draft.rules) { $rule in
                    HStack {
                        Picker("Provider", selection: $rule.provider) {
                            ForEach(TicketProviderKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 110)
                        TextField("Project key", text: $rule.projectKey, prompt: Text(rule.provider == .jira ? "Any project" : "All stories"))
                            .disabled(rule.provider == .shortcut)
                            .frame(width: 130)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Picker("Repository", selection: $rule.repositoryID) {
                            ForEach(draft.repositories) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden()
                        Button(role: .destructive) { draft.rules.removeAll { $0.id == rule.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Add Rule") {
                    if let first = draft.repositories.first {
                        draft.rules.append(RepositoryRule(provider: .jira, repositoryID: first.id))
                    }
                }
                .disabled(draft.repositories.isEmpty)
            } header: {
                Text("Routing")
            } footer: {
                Text("Suggests a repository for each ticket. A Jira project key rule (e.g. PLAT) wins over an empty one. You can still pick another repository before the first investigation.")
            }

            Section {
                HStack {
                    TextField("Worktrees folder", text: $draft.worktreeRoot, prompt: Text(WorkspaceSettings.defaultWorktreeRoot))
                    Button("Choose…") { chooseWorktreeRoot() }
                }
            } header: {
                Text("Worktrees")
            } footer: {
                Text("Each ticket gets its own worktree at <folder>/<repository>/<ticket>, on a devpilot/… branch.")
            }
        }
        .formStyle(.grouped)
        .onAppear { draft = model.workspaceSettings }
        .onChange(of: draft) { model.applyWorkspaceSettings(draft) }
    }

    private func remove(_ id: String) {
        draft.repositories.removeAll { $0.id == id }
        draft.rules.removeAll { $0.repositoryID == id }
    }

    private func addRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Repository"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isAdding = true
        error = nil
        Task {
            defer { isAdding = false }
            do {
                let inspection = try await GitWorktreeManager(worktreeRoot: draft.resolvedWorktreeRoot).inspect(path: url.path)
                guard !draft.repositories.contains(where: { $0.path == inspection.topLevel }) else {
                    error = "That repository is already added."
                    return
                }
                draft.repositories.append(RepositoryConfig(
                    name: URL(filePath: inspection.topLevel).lastPathComponent,
                    path: inspection.topLevel,
                    baseBranch: inspection.defaultBranch ?? "main"
                ))
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func chooseWorktreeRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url {
            draft.worktreeRoot = url.path
        }
    }
}

/// Claude Code location, login check, model and time limit. Changes apply immediately.
struct AgentSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = AgentSettings()
    @State private var status: String?
    @State private var statusIsError = false
    @State private var isChecking = false

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Executable", text: $draft.claudePath, prompt: Text(detectedPath ?? "Not found, choose its location"))
                    Button("Choose…") { chooseExecutable() }
                }
                HStack {
                    Button("Check") { Task { await check() } }
                        .disabled(isChecking)
                    if isChecking {
                        ProgressView().controlSize(.small)
                    } else if let status {
                        Label(status, systemImage: statusIsError ? "xmark.octagon.fill" : "checkmark.circle.fill")
                            .foregroundStyle(statusIsError ? .red : .green)
                            .lineLimit(2)
                    }
                }
                TextField("Model", text: $draft.model, prompt: Text("Account default (e.g. opus, sonnet)"))
                Stepper(value: $draft.investigationTimeoutMinutes, in: 5...120, step: 5) {
                    Text("Investigation time limit: \(draft.investigationTimeoutMinutes) min")
                }
            } header: {
                Text("Claude Code")
            } footer: {
                Text("""
                    Leave the executable empty to detect it automatically. DevPilot uses your claude.ai login, \
                    never ANTHROPIC_API_KEY. During investigation Claude can only read files (Read, Grep, Glob); \
                    the repository's own .claude settings, hooks and MCP servers are ignored.
                    """)
            }
        }
        .formStyle(.grouped)
        .onAppear { draft = model.agentSettings }
        .onChange(of: draft) {
            model.applyAgentSettings(draft)
            status = nil
        }
    }

    private var detectedPath: String? {
        ClaudeCLI.resolve(configuredPath: "")?.path
    }

    private func check() async {
        isChecking = true
        defer { isChecking = false }
        guard let executable = model.resolvedClaudeExecutable else {
            status = draft.claudePath.isEmpty ? "Claude Code was not found." : "\(draft.claudePath) is not executable."
            statusIsError = true
            return
        }
        do {
            let result = try await ClaudeCLI.status(executable: executable)
            status = result.summary
            statusIsError = !result.loggedIn
        } catch {
            status = error.localizedDescription
            statusIsError = true
        }
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.prompt = "Use"
        if panel.runModal() == .OK, let url = panel.url {
            draft.claudePath = url.path
        }
    }
}
