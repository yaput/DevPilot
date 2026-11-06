import AppKit
import DevPilotCore
import SwiftUI

/// Repositories, routing rules and the worktree folder. Changes apply immediately.
struct RepositoriesSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = WorkspaceSettings()
    @State private var error: String?
    @State private var isAdding = false
    @State private var configuringID: String?
    @State private var configuringLocalRunID: String?

    var body: some View {
        Form {
            if model.hasActiveRuns {
                RunningAgentBanner()
            }
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
                        BaseBranchField(title: "Base branch", branch: $repository.baseBranch, repositoryPath: repository.path)
                        HStack {
                            Text(commandSummary(repository))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Button("Configure Commands…") { configuringID = repository.id }
                                .controlSize(.small)
                            Button("Configure Local Run…") { configuringLocalRunID = repository.id }
                                .controlSize(.small)
                        }
                        AutopilotToggles(autopilot: $repository.autopilot)
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
                            ForEach(TicketProviderKind.synced, id: \.self) { Text($0.displayName).tag($0) }
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
                Picker("Open worktrees with", selection: $draft.editorBundleID) {
                    Text(model.editors.first.map { "Automatic (\($0.name))" } ?? "Automatic").tag("")
                    ForEach(model.editors) { Text($0.name).tag($0.bundleID) }
                }
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
        .disabled(model.hasActiveRuns)
        .onAppear { draft = model.workspaceSettings }
        .onChange(of: draft) { model.applyWorkspaceSettings(draft) }
        .sheet(isPresented: Binding(get: { configuringID != nil }, set: { if !$0 { configuringID = nil } })) {
            if let index = draft.repositories.firstIndex(where: { $0.id == configuringID }) {
                RepositoryCommandsSheet(repository: $draft.repositories[index])
            }
        }
        .sheet(isPresented: Binding(get: { configuringLocalRunID != nil }, set: { if !$0 { configuringLocalRunID = nil } })) {
            if let index = draft.repositories.firstIndex(where: { $0.id == configuringLocalRunID }) {
                LocalRunSheet(repository: $draft.repositories[index])
            }
        }
    }

    private func commandSummary(_ repository: RepositoryConfig) -> String {
        let setup = repository.setupCommands.filter(\.isEnabled).count
        let validation = repository.validationCommands.filter(\.isEnabled).count
        let agent = repository.agentCommands.filter(\.isEnabled).count
        return "\(setup) setup · \(validation) validation · Claude may run \(agent)"
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
                let presets = CommandPresets.detect(repositoryAt: inspection.topLevel)
                var repository = RepositoryConfig(
                    name: URL(filePath: inspection.topLevel).lastPathComponent,
                    path: inspection.topLevel,
                    baseBranch: inspection.defaultBranch ?? "main",
                    setupCommands: presets.setup,
                    agentCommands: presets.agent,
                    validationCommands: presets.validation
                )
                let (localRun, secrets) = LocalRunPresets.detect(repositoryAt: inspection.topLevel)
                repository.localRun = localRun
                repository.validationDatabase = localRun.database.isEnabled && CommandPresets.needsDatabase(presets.validation)
                repository.validationEnvironment = CommandPresets.validationEnvironment(for: presets.validation)
                repository.qa.login = LoginPresets.detect(repositoryAt: inspection.topLevel)
                for (name, value) in secrets {
                    model.setRepositorySecret(repository.id, name, value: value)
                }
                draft.repositories.append(repository)
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
    @State private var importStatus: String?

    var body: some View {
        Form {
            if model.hasActiveRuns {
                RunningAgentBanner()
            }
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
                Stepper(value: $draft.implementationTimeoutMinutes, in: 5...180, step: 5) {
                    Text("Implementation time limit: \(draft.implementationTimeoutMinutes) min")
                }
                .help("A safety cap. Claude is stopped sooner if it produces no output for 15 minutes; a stopped run can be continued in the same session.")
                Stepper(value: $draft.validationTimeoutMinutes, in: 1...120, step: 1) {
                    Text("Time limit per validation command: \(draft.validationTimeoutMinutes) min")
                }
                Stepper(value: $draft.automaticFixAttempts, in: 0...3) {
                    Text("Automatic fix attempts when tests fail: \(draft.automaticFixAttempts)")
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
            .disabled(model.hasActiveRuns)
            Section {
                Stepper(value: $draft.maxParallelAgents, in: 1...8) {
                    Text("Tickets Claude works on at once: \(draft.maxParallelAgents)")
                }
                .help("Investigation, implementation and review mostly wait on Claude. More at once uses your Claude usage faster.")
                Stepper(value: $draft.maxParallelBuilds, in: 1...4) {
                    Text("Builds and tests at once: \(draft.maxParallelBuilds)")
                }
                .help("Setup and test commands run locally, about 2–4 GB each. They also wait while macOS reports memory pressure.")
            } header: {
                Text("Parallel runs")
            } footer: {
                Text("""
                    Can be changed while runs are active. A ticket waits only for its build and test commands, not \
                    for whole runs, and those run at low priority so the apps you use stay responsive.
                    """)
            }
            Section {
                TextField("PATH", text: $draft.toolPath, prompt: Text("Imported from your login shell on first implementation"), axis: .vertical)
                    .font(.callout.monospaced())
                    .lineLimit(1...4)
                TextField("JAVA_HOME", text: $draft.javaHome, prompt: Text("Not set"))
                    .font(.callout.monospaced())
                HStack {
                    Button("Import from Login Shell") { Task { await importEnvironment() } }
                    if let importStatus {
                        Text(importStatus).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Build tools")
            } footer: {
                Text("""
                    Apps opened from Finder don't see your shell's PATH, so java, mvn, node and pnpm would not be found. \
                    Only PATH and JAVA_HOME are imported; nothing else from your shell profile is passed to builds.
                    """)
            }
            .disabled(model.hasActiveRuns)
        }
        .formStyle(.grouped)
        .onAppear { draft = model.agentSettings }
        .onChange(of: draft) {
            model.applyAgentSettings(draft)
            status = nil
        }
    }

    private func importEnvironment() async {
        importStatus = "Importing…"
        do {
            let environment = try await ToolEnvironment.importFromLoginShell()
            draft.toolPath = environment.path
            draft.javaHome = environment.javaHome
            importStatus = "Imported."
        } catch {
            importStatus = error.localizedDescription
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

/// Per-repository command lists: everything detected starts checked; uncheck what isn't needed.
/// A repository's autopilot switches. Plan approval always stays with the user.
private struct AutopilotToggles: View {
    @Binding var autopilot: AutopilotConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { autopilot.investigatesNewTickets },
                // Only tickets from now on: the backlog is never picked up.
                set: { autopilot.investigateNewSince = $0 ? Date() : nil }
            )) {
                Label("Investigate new tickets automatically", systemImage: "magnifyingglass")
            }
            .help("Tickets that arrive from now on are investigated as soon as they sync (every 5 minutes). Tickets already here are left alone.")
            Toggle(isOn: $autopilot.implementWhenApproved) {
                Label("Implement as soon as I approve a plan", systemImage: "hammer")
            }
            .help("Approving a plan starts implementation, then tests and review. You still approve every plan.")
            if let since = autopilot.investigateNewSince {
                Text("Autopilot investigates tickets that arrived after \(since.formatted(date: .abbreviated, time: .shortened)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .controlSize(.small)
        .padding(.top, 2)
    }
}

private struct RepositoryCommandsSheet: View {
    @Binding var repository: RepositoryConfig
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    CommandList(rules: $repository.setupCommands, placeholder: "e.g. pnpm install --frozen-lockfile", allowsOptional: true)
                } header: {
                    Text("Setup commands")
                } footer: {
                    Text("Run by DevPilot in a fresh worktree before Claude starts, with network access, in this order. Use them to install dependencies.")
                }
                Section {
                    CommandList(rules: $repository.validationCommands, placeholder: "e.g. cd services/ui && pnpm run test", allowsPathFilter: true)
                    Toggle("Give tests a throwaway Postgres database", isOn: $repository.validationDatabase)
                        .disabled(!repository.localRun.database.isEnabled && !repository.validationDatabase)
                        .help(repository.localRun.database.isEnabled ? "" : "Set up the database connection under Local Run first.")
                    TextField("Environment", text: $repository.validationEnvironment, prompt: Text("KEY=VALUE, one per line"), axis: .vertical)
                        .font(.callout.monospaced())
                        .lineLimit(2...6)
                        .help("Set for every validation command, like CI's job environment, e.g. RAILS_LOG_LEVEL=error.")
                } header: {
                    Text("Validation commands")
                } footer: {
                    Text("Run by DevPilot after every implementation and fix, in the sandbox (no network, writes only in the worktree and build caches). Each must exit 0. Results go to the reviewer and to you. \"Only if changed\" takes path prefixes (e.g. frontend/): the command is skipped when the ticket changed nothing under them. $DEVPILOT_CHANGED_FILES lists the files the ticket changed (one per line) and $DEVPILOT_BASE_COMMIT its starting commit, to test only what changed, e.g. pnpm vitest related --run $DEVPILOT_CHANGED_FILES. The test database is created for each run through the Local Run connection, owned by a one-off role (the tests never see your credentials), passed as DATABASE_URL and PG* variables, and dropped afterwards.")
                }
                Section {
                    CommandList(rules: $repository.agentCommands, placeholder: "e.g. ./mvnw or pnpm")
                } header: {
                    Text("Commands Claude may run")
                } footer: {
                    Text("Each entry allows that command with any arguments (`pnpm` allows `pnpm test`, `pnpm lint`, …). They run in the sandbox: no network, no writes outside the worktree and build caches, no git commits.")
                }
                Section {
                    DisclosureGroup("Always blocked (\(CommandPresets.alwaysDenied.count))") {
                        Text(CommandPresets.alwaysDenied.joined(separator: ", "))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Detect from Project") { addDetectedPresets() }
                    .help("Adds suggested commands for the build files found in the repository. Existing entries are kept.")
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 620, height: 700)
        .navigationTitle(repository.name)
    }

    private func addDetectedPresets() {
        let presets = CommandPresets.detect(repositoryAt: repository.path)
        for rule in presets.setup where !repository.setupCommands.contains(where: { $0.command == rule.command }) {
            repository.setupCommands.append(rule)
        }
        for rule in presets.agent where !repository.agentCommands.contains(where: { $0.command == rule.command }) {
            repository.agentCommands.append(rule)
        }
        for rule in presets.validation where !repository.validationCommands.contains(where: { $0.command == rule.command }) {
            repository.validationCommands.append(rule)
        }
    }
}

private struct CommandList: View {
    @Binding var rules: [CommandRule]
    let placeholder: String
    /// Setup commands can be optional: a failure is a warning, not a stop.
    var allowsOptional = false
    /// Validation commands can be limited to tickets that change certain paths.
    var allowsPathFilter = false

    var body: some View {
        if rules.isEmpty {
            Text("None.").foregroundStyle(.secondary)
        }
        ForEach($rules) { $rule in
            HStack {
                Toggle("Enabled", isOn: $rule.isEnabled).labelsHidden()
                TextField("Command", text: $rule.command, prompt: Text(placeholder))
                    .font(.callout.monospaced())
                    .labelsHidden()
                    .foregroundStyle(rule.isEnabled ? .primary : .secondary)
                if allowsPathFilter {
                    TextField("Only if changed", text: $rule.onlyIfChanged, prompt: Text("any change"))
                        .font(.callout.monospaced())
                        .labelsHidden()
                        .frame(width: 110)
                        .help("Only if changed: run this command only when the ticket changed a file under one of these space-separated paths, e.g. frontend/. Empty: always.")
                }
                if allowsOptional {
                    Toggle("Optional", isOn: $rule.isOptional)
                        .toggleStyle(.checkbox)
                        .help("If this command fails, DevPilot logs a warning and continues instead of stopping.")
                }
                Button(role: .destructive) { rules.removeAll { $0.id == rule.id } } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
            }
        }
        Button("Add Command") { rules.append(CommandRule(command: "")) }
    }
}

struct RunningAgentBanner: View {
    var body: some View {
        Label("An agent is running. Settings that affect it are locked until it finishes.", systemImage: "lock.fill")
            .foregroundStyle(.orange)
    }
}
