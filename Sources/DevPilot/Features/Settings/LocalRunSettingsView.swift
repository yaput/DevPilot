import DevPilotCore
import SwiftUI

/// Per-repository "Run Locally" setup: containers, services, database copy, files to copy and
/// Keychain secrets. Secret values are write-only here and are never given to an agent.
struct LocalRunSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Binding var repository: RepositoryConfig
    @State private var confirmingDetect = false
    @State private var newFile = ""
    @State private var newRestoreFile = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                dependenciesSection
                servicesSection
                databaseSection
                filesSection
                // Sign-in credentials have their own fields in the QA section.
                SecretsSection(repositoryID: repository.id, names: $repository.localRun.secretNames,
                               hidden: Set(repository.qa.login.secretNames))
                QASignInSection(repository: $repository)
                Section {
                    TextField("App URL", text: $repository.localRun.appURL, prompt: Text("http://localhost:{{port.web}}"))
                        .font(.callout.monospaced())
                } header: {
                    Text("App URL")
                } footer: {
                    Text("""
                        Placeholders, filled in per run: {{port.NAME}} (a free port for each service), {{database}} (the run's \
                        database copy), {{db.host}}, {{db.port}}, {{db.user}}, {{secret.NAME}} (from the Keychain), {{worktree}}.
                        """)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Detect from Project…") { confirmingDetect = true }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 760, height: 820)
        .confirmationDialog("Replace these settings with the detected ones?", isPresented: $confirmingDetect) {
            Button("Replace") { detect() }
        } message: {
            Text("Reads docker-compose, Procfile, Rails / Spring Boot / Vite projects and .env files in \(repository.path).")
        }
    }

    // MARK: Sections

    private var dependenciesSection: some View {
        Section {
            ForEach($repository.localRun.dependencies) { $dependency in
                HStack {
                    Toggle("Enabled", isOn: $dependency.isEnabled).labelsHidden()
                    TextField("Name", text: $dependency.name).frame(width: 110)
                    TextField("Port", value: $dependency.port, format: .number.grouping(.never)).frame(width: 64)
                    TextField("Start command", text: $dependency.startCommand, prompt: Text("e.g. podman compose up -d db"))
                        .font(.callout.monospaced())
                    removeButton { repository.localRun.dependencies.removeAll { $0.id == dependency.id } }
                }
            }
            Button("Add Dependency") { repository.localRun.dependencies.append(.init(name: "", port: 0, startCommand: "")) }
        } header: {
            Text("Dependencies")
        } footer: {
            Text("Checked before each run: if nothing listens on the port, the start command runs. Shared with your own runs; not stopped afterwards.")
        }
    }

    private var servicesSection: some View {
        Section {
            ForEach($repository.localRun.services) { $service in
                ServiceEditor(service: $service) {
                    repository.localRun.services.removeAll { $0.id == service.id }
                }
            }
            Button("Add Service") {
                repository.localRun.services.append(.init(name: "service", portName: "", command: ""))
            }
        } header: {
            Text("Services")
        } footer: {
            Text("Started in order from the ticket's worktree, without a sandbox, like you would run them. A service with a port name gets a free port ({{port.NAME}}) and is ready once HTTP on that port answers below 500.")
        }
    }

    private var databaseSection: some View {
        Section {
            Toggle("Give each run its own database copy", isOn: $repository.localRun.database.isEnabled)
            Group {
                HStack {
                    TextField("Host", text: $repository.localRun.database.host)
                    TextField("Port", value: $repository.localRun.database.port, format: .number.grouping(.never)).frame(width: 80)
                    TextField("User", text: $repository.localRun.database.user)
                }
                TextField("Template database", text: $repository.localRun.database.templateName)
                    .font(.callout.monospaced())
                TextField("Password secret", text: $repository.localRun.database.passwordSecret, prompt: Text("db_password"))
            }
            .disabled(!repository.localRun.database.isEnabled)
        } header: {
            Text("Database")
        } footer: {
            Text("Each run gets CREATE DATABASE … TEMPLATE <template> as {{database}}, dropped when the run stops. Branch migrations and test data never touch your own database.")
        }
    }

    @ViewBuilder
    private var filesSection: some View {
        Section {
            ForEach(repository.localRun.copyFiles, id: \.self) { file in
                HStack {
                    Text(file).font(.callout.monospaced())
                    Spacer()
                    removeButton { repository.localRun.copyFiles.removeAll { $0 == file } }
                }
            }
            HStack {
                TextField("Path relative to the repository", text: $newFile, prompt: Text("e.g. frontend/.env"))
                    .font(.callout.monospaced())
                Button("Add") {
                    let file = newFile.trimmingCharacters(in: .whitespaces)
                    if !file.isEmpty && !repository.localRun.copyFiles.contains(file) { repository.localRun.copyFiles.append(file) }
                    newFile = ""
                }
            }
        } header: {
            Text("Files copied from your main checkout")
        } footer: {
            Text("Untracked files a worktree lacks, such as .env. Copied in for the run and removed afterwards.")
        }
        Section {
            ForEach(repository.localRun.restoreFiles, id: \.self) { file in
                HStack {
                    Text(file).font(.callout.monospaced())
                    Spacer()
                    removeButton { repository.localRun.restoreFiles.removeAll { $0 == file } }
                }
            }
            HStack {
                TextField("Path relative to the repository", text: $newRestoreFile, prompt: Text("e.g. db/structure.sql"))
                    .font(.callout.monospaced())
                Button("Add") {
                    let file = newRestoreFile.trimmingCharacters(in: .whitespaces)
                    if !file.isEmpty && !repository.localRun.restoreFiles.contains(file) { repository.localRun.restoreFiles.append(file) }
                    newRestoreFile = ""
                }
            }
        } header: {
            Text("Restored after the run")
        } footer: {
            Text("Tracked files the run rewrites, such as the schema dump after migrations. Saved before setup and put back when the run stops, so they never end up in the branch.")
        }
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
    }

    private func detect() {
        let (config, secrets) = LocalRunPresets.detect(repositoryAt: repository.path)
        repository.localRun = config
        for (name, value) in secrets where !model.hasRepositorySecret(repository.id, name) {
            model.setRepositorySecret(repository.id, name, value: value)
        }
    }
}

private struct ServiceEditor: View {
    @Binding var service: LocalRunConfig.Service
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("Enabled", isOn: $service.isEnabled).labelsHidden()
                TextField("Name", text: $service.name).font(.headline).frame(width: 150)
                TextField("Port name", text: $service.portName, prompt: Text("none (worker)")).frame(width: 120)
                    .help("Gives this service a free port, used as {{port.NAME}}. Leave empty for background workers.")
                TextField("Folder", text: $service.directory, prompt: Text("repository root")).frame(width: 150)
                Spacer()
                Button(role: .destructive, action: remove) { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
            }
            TextField("Command", text: $service.command, axis: .vertical)
                .font(.callout.monospaced())
                .lineLimit(1...3)
            ForEach($service.environment) { $variable in
                HStack {
                    TextField("KEY", text: $variable.key).font(.callout.monospaced()).frame(width: 220)
                    Text("=")
                    TextField("value", text: $variable.value).font(.callout.monospaced())
                    Button(role: .destructive) { service.environment.removeAll { $0.id == variable.id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            HStack {
                Button("Add Variable") { service.environment.append(.init(key: "", value: "")) }.controlSize(.small)
                Spacer()
                if !service.portName.isEmpty {
                    TextField("Ready path", text: $service.readyPath).frame(width: 120).controlSize(.small)
                }
                Stepper("Ready within \(service.readyTimeoutSeconds)s", value: $service.readyTimeoutSeconds, in: 10...900, step: 10)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
        .opacity(service.isEnabled ? 1 : 0.6)
    }
}

/// Secret values can be set or replaced but are never displayed.
struct SecretsSection: View {
    @Environment(AppModel.self) private var model
    let repositoryID: String
    @Binding var names: [String]
    var hidden: Set<String> = []
    @State private var drafts: [String: String] = [:]
    @State private var newName = ""
    @State private var revision = 0

    var body: some View {
        Section {
            ForEach(names.filter { !hidden.contains($0) }, id: \.self) { name in
                HStack {
                    Text(name).font(.callout.monospaced()).frame(width: 150, alignment: .leading)
                    SecureField("Value", text: Binding(get: { drafts[name] ?? "" }, set: { drafts[name] = $0 }),
                                prompt: Text(model.hasRepositorySecret(repositoryID, name) ? "Saved in Keychain. Type to replace." : "Not set"))
                    Button("Save") {
                        if let value = drafts[name], !value.isEmpty {
                            model.setRepositorySecret(repositoryID, name, value: value)
                            drafts[name] = nil
                            revision += 1
                        }
                    }
                    .disabled((drafts[name] ?? "").isEmpty)
                    if model.hasRepositorySecret(repositoryID, name) {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    }
                    Button(role: .destructive) {
                        model.deleteRepositorySecret(repositoryID, name)
                        names.removeAll { $0 == name }
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
                .id("\(name)-\(revision)")
            }
            HStack {
                TextField("Secret name", text: $newName, prompt: Text("e.g. qa_password"))
                Button("Add") {
                    let name = newName.trimmingCharacters(in: .whitespaces)
                    if name.wholeMatch(of: /[A-Za-z0-9_]+/) != nil, !names.contains(name) { names.append(name) }
                    newName = ""
                }
            }
        } header: {
            Text("Secrets (Keychain)")
        } footer: {
            Text("Used as {{secret.NAME}} in commands and variables. Values stay in your Keychain and are only filled in by DevPilot itself; no agent ever receives them.")
        }
    }
}

/// How DevPilot signs in to the local run before QA sessions, plus its Playwright install.
/// The repository's QA notes, carried from one QA session to the next.
private struct QAMemoryRow: View {
    @Environment(AppModel.self) private var model
    let repositoryID: String
    @State private var revision = 0

    var body: some View {
        let store = QAMemoryStore(artifacts: model.artifacts)
        let memory = revision >= 0 ? store.read(repositoryID: repositoryID) : nil
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("QA notes")
                Text(memory.map { "\($0.split(separator: "\n").count) lines, updated after each session" }
                     ?? "None yet. Written after the first QA session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if memory != nil {
                Button("View") { NSWorkspace.shared.open(store.url(repositoryID: repositoryID)) }
                Button("Forget", role: .destructive) {
                    store.forget(repositoryID: repositoryID)
                    revision += 1
                }
                .help("The next QA session starts without notes.")
            }
        }
        .controlSize(.small)
    }
}

private struct QASignInSection: View {
    @Environment(AppModel.self) private var model
    @Binding var repository: RepositoryConfig
    @State private var confirmingInstall = false

    private var login: Binding<LoginConfig> { $repository.qa.login }

    var body: some View {
        Section {
            toolsRow
            Stepper("QA session time limit: \(repository.qa.timeLimitMinutes) min", value: $repository.qa.timeLimitMinutes, in: 5...60, step: 5)
            Toggle("Run a QA session after tests pass, before the review", isOn: $repository.qa.runInPipeline)
                .help("""
                    DevPilot starts the app from the ticket's worktree, has the QA agent test it, and sends reproduced bugs to \
                    the automatic fix loop. One app runs locally at a time, so tickets take turns.
                    """)
            QAMemoryRow(repositoryID: repository.id)
            Toggle("Sign in before QA sessions", isOn: login.isEnabled)
            ForEach(login.wrappedValue.secretNames, id: \.self) { name in
                CredentialField(repositoryID: repository.id, name: name)
            }
            Group {
                HStack {
                    TextField("Sign-in page", text: login.loginPath, prompt: Text("/login")).font(.callout.monospaced())
                    TextField("Check page", text: login.checkPath, prompt: Text("/")).font(.callout.monospaced())
                        .help("A page that needs a session. It is opened with only the saved session to prove the sign-in held.")
                    Stepper("Step timeout \(login.wrappedValue.timeoutSeconds)s", value: login.timeoutSeconds, in: 5...120, step: 5)
                        .fixedSize()
                }
                HStack {
                    Text("Script").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Menu("Use Preset") {
                        Button("Clerk") { apply(LoginPresets.clerk(loginPath: login.wrappedValue.loginPath)) }
                        Button("Email and Password Form") { apply(LoginPresets.form(loginPath: login.wrappedValue.loginPath)) }
                        Divider()
                        Button("Detect from Project") {
                            let detected = LoginPresets.detect(repositoryAt: repository.path)
                            login.wrappedValue.loginPath = detected.loginPath
                            apply(detected.script)
                        }
                    }
                    .fixedSize()
                }
                TextEditor(text: login.script)
                    .font(.callout.monospaced())
                    .frame(minHeight: 140)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
            }
            .disabled(!login.wrappedValue.isEnabled)
        } header: {
            Text("Sign-in for QA")
        } footer: {
            Text("""
                DevPilot runs this Playwright script itself, as `async ({ page, context, secret, baseURL }) => { … }`, then saves \
                the browser session for the QA agent. The script refers to credentials only as secret('NAME'); their values \
                are kept in the Keychain and never reach an agent. Test it with Test Sign-in on a running app.
                """)
        }
        .confirmationDialog("Install QA browser tools?", isPresented: $confirmingInstall) {
            Button("Install") { Task { await model.installQATools() } }
        } message: {
            Text("""
                Runs `npm install @playwright/mcp@\(QATools.mcpVersion)` (install scripts disabled) in \
                \(model.qaTools.directory.path). \(QATools.browserChannel == nil
                    ? "Google Chrome was not found, so Playwright's Chromium is downloaded too."
                    : "Your installed Google Chrome is used as the browser.")
                """)
        }
    }

    @ViewBuilder
    private var toolsRow: some View {
        let _ = model.qaToolsRevision
        HStack {
            if model.qaToolsInstalling {
                ProgressView().controlSize(.small)
                Text("Installing QA browser tools…")
            } else if model.qaTools.isInstalled {
                Label("QA browser tools installed (Playwright MCP \(QATools.mcpVersion))", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label("QA browser tools are not installed.", systemImage: "shippingbox")
                Spacer()
                Button("Install…") { confirmingInstall = true }
            }
        }
    }

    private func apply(_ script: String) {
        login.wrappedValue.script = script
    }
}

/// One sign-in credential, saved to the Keychain. A username is shown once saved; passwords and
/// anything else stay write-only.
private struct CredentialField: View {
    @Environment(AppModel.self) private var model
    let repositoryID: String
    let name: String
    @State private var draft = ""
    @State private var isSaved = false

    private var isUsername: Bool {
        name == LoginPresets.usernameSecret || ["user", "email", "login"].contains { name.localizedCaseInsensitiveContains($0) }
    }

    private var label: String {
        switch name {
        case LoginPresets.usernameSecret: "Username"
        case LoginPresets.passwordSecret: "Password"
        default: name
        }
    }

    var body: some View {
        HStack {
            Text(label).frame(width: 90, alignment: .leading)
            if isUsername {
                TextField(label, text: $draft, prompt: Text("Email or username of the test account"))
                    .labelsHidden()
                    .onSubmit(save)
            } else {
                SecureField(label, text: $draft, prompt: Text(isSaved ? "Saved. Type to replace." : "Not set"))
                    .labelsHidden()
                    .onSubmit(save)
            }
            Button("Save", action: save)
                .disabled(draft.isEmpty || (isUsername && draft == model.repositorySecret(repositoryID, name)))
            Image(systemName: isSaved ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(isSaved ? .green : .orange)
                .help(isSaved ? "Saved in the Keychain" : "Not set")
        }
        .onAppear(perform: load)
        .onChange(of: name) { load() }
    }

    private func load() {
        isSaved = model.hasRepositorySecret(repositoryID, name)
        draft = isUsername ? model.repositorySecret(repositoryID, name) ?? "" : ""
    }

    private func save() {
        let value = isUsername ? draft.trimmingCharacters(in: .whitespacesAndNewlines) : draft
        guard !value.isEmpty else { return }
        model.setRepositorySecret(repositoryID, name, value: value)
        isSaved = model.hasRepositorySecret(repositoryID, name)
        if !isUsername { draft = "" }
    }
}
