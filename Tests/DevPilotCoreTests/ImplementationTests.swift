import Darwin
import Foundation
import Synchronization
import Testing
@testable import DevPilotCore

/// Drives a ticket to `approved` with a real worktree, the way the app does.
struct ApprovedTicket {
    let repo: TestRepository
    let db: AppDatabase
    let ticket: Ticket
    let workspace: TicketWorkspace
    let plan: DecisionDocument
    let artifacts: ArtifactStore

    init(files: [String: String] = ["README.md": "# Payments\n", "Sources/Webhooks.swift": "func deliver() {}\n"]) async throws {
        repo = try await TestRepository(files: files)
        db = try AppDatabase.inMemory()
        ticket = .sample()
        artifacts = ArtifactStore(root: repo.root.appending(path: "artifacts", directoryHint: .isDirectory))
        try await db.recordSync([ticket], for: .jira)
        try await db.transition(ticketID: ticket.id, to: .selected, message: "")
        let doc = try await InvestigationService(
            database: db, worktrees: repo.manager, runner: FakeAgentRunner(), artifacts: artifacts
        ).investigate(ticketID: ticket.id, repository: repo.config) { _ in }
        _ = try await db.recordApproval(ticketID: ticket.id, decision: .approved, planHash: doc.contentHash, notes: "")
        plan = doc
        workspace = try #require(try await db.workspace(ticketID: ticket.id))
    }

    func service(_ runner: any AgentRunner) -> ImplementationService {
        ImplementationService(database: db, worktrees: repo.manager, runner: runner, artifacts: artifacts)
    }

    var worktree: URL { URL(filePath: workspace.worktreePath, directoryHint: .isDirectory) }
}

struct ImplementationServiceTests {
    let tools = ToolEnvironment(path: "/opt/test/bin", javaHome: "/opt/test/jdk")

    @Test func implementsRecordsChangedFilesAndMovesToValidating() async throws {
        let fixture = try await ApprovedTicket()
        defer { fixture.repo.remove() }
        let worktree = fixture.worktree
        let runner = FakeAgentRunner(implement: { _ in
            try "func deliver() { retry() }\n".write(to: worktree.appending(path: "Sources/Webhooks.swift"), atomically: true, encoding: .utf8)
            try "func retry() {}\n".write(to: worktree.appending(path: "Sources/Retry.swift"), atomically: true, encoding: .utf8)
            return .sample()
        })
        var config = fixture.repo.config
        config.agentCommands = [CommandRule(command: "./mvnw"), CommandRule(command: "pnpm", isEnabled: false)]

        let result = try await fixture.service(runner).implement(ticketID: fixture.ticket.id, repository: config, tools: tools) { _ in }

        #expect(try await fixture.db.state(of: fixture.ticket.id) == .validating)
        #expect(Set(result.changedFiles) == [
            ChangedFile(path: "Sources/Webhooks.swift", change: .modified),
            ChangedFile(path: "Sources/Retry.swift", change: .untracked),
        ])
        #expect(result.planVersion == fixture.plan.version)
        let request = try #require(runner.implementations.first)
        #expect(request.plan.contentHash == fixture.plan.contentHash)
        #expect(request.allowedCommands == ["./mvnw"])
        #expect(request.tools == tools)
        #expect(GitWorktreeManager.realPath(request.commonGitDirectory) == GitWorktreeManager.realPath(fixture.repo.repo.appending(path: ".git").path))
        let run = try #require(try await fixture.db.runs(ticketID: fixture.ticket.id).last)
        #expect(run.kind == .implementation)
        #expect(run.outcome == .succeeded)
        #expect(run.implementation == result)
    }

    @Test func refusesWithoutValidApproval() async throws {
        let fixture = try await ApprovedTicket()
        defer { fixture.repo.remove() }
        let runner = FakeAgentRunner()
        try await fixture.db.transition(ticketID: fixture.ticket.id, to: .cancelled, message: "")

        await #expect(throws: WorkflowError.implementationBlocked(.wrongState(.cancelled))) {
            _ = try await fixture.service(runner).implement(ticketID: fixture.ticket.id, repository: fixture.repo.config, tools: tools) { _ in }
        }
        #expect(runner.implementations.isEmpty)
    }

    @Test func setupCommandsRunInWorktreeWithToolEnvironmentBeforeAgent() async throws {
        let fixture = try await ApprovedTicket()
        defer { fixture.repo.remove() }
        let order = Mutex<[String]>([])
        let worktree = fixture.worktree
        let runner = FakeAgentRunner(implement: { _ in
            order.withLock { $0.append("agent") }
            #expect(FileManager.default.fileExists(atPath: worktree.appending(path: "setup-ran.txt").path))
            return .sample()
        })
        var config = fixture.repo.config
        config.setupCommands = [
            CommandRule(command: #"printf '%s|%s|%s' "$JAVA_HOME" "$CI" "${ANTHROPIC_API_KEY:-none}" > setup-ran.txt"#),
            CommandRule(command: "exit 1", isEnabled: false),
        ]

        _ = try await fixture.service(runner).implement(ticketID: fixture.ticket.id, repository: config, tools: tools) { _ in }

        let recorded = try String(contentsOf: worktree.appending(path: "setup-ran.txt"), encoding: .utf8)
        #expect(recorded == "/opt/test/jdk|true|none")
        #expect(order.withLock { $0 } == ["agent"])
    }

    @Test func failingSetupStopsBeforeTheAgent() async throws {
        let fixture = try await ApprovedTicket()
        defer { fixture.repo.remove() }
        let runner = FakeAgentRunner()
        var config = fixture.repo.config
        config.setupCommands = [CommandRule(command: "echo 'registry unreachable' >&2; exit 7")]

        await #expect(throws: ImplementationError.self) {
            _ = try await fixture.service(runner).implement(ticketID: fixture.ticket.id, repository: config, tools: tools) { _ in }
        }
        #expect(runner.implementations.isEmpty)
        #expect(try await fixture.db.state(of: fixture.ticket.id) == .failed)
        let run = try #require(try await fixture.db.runs(ticketID: fixture.ticket.id).last)
        #expect(run.errorMessage?.contains("registry unreachable") == true)
        let setupLog = URL(filePath: run.logPath).deletingPathExtension().appendingPathExtension("setup.log")
        #expect(try String(contentsOf: setupLog, encoding: .utf8).contains("registry unreachable"))
    }

    @Test func commitsByTheAgentAreDetected() async throws {
        let fixture = try await ApprovedTicket()
        defer { fixture.repo.remove() }
        let repo = fixture.repo
        let worktree = fixture.worktree
        let runner = FakeAgentRunner(implement: { _ in
            try "x\n".write(to: worktree.appending(path: "sneaky.txt"), atomically: true, encoding: .utf8)
            try await repo.git("add", "-A", in: worktree)
            try await repo.git("-c", "user.email=a@b", "-c", "user.name=agent", "commit", "-qm", "sneaky", in: worktree)
            return .sample()
        })

        await #expect(throws: ImplementationError.self) {
            _ = try await fixture.service(runner).implement(ticketID: fixture.ticket.id, repository: fixture.repo.config, tools: tools) { _ in }
        }
        #expect(try await fixture.db.state(of: fixture.ticket.id) == .failed)
        #expect(try await fixture.db.runs(ticketID: fixture.ticket.id).last?.errorMessage?.contains("DevPilot never commits") == true)
    }

    @Test func failedImplementationCanReturnToTheApprovedPlan() async throws {
        let fixture = try await ApprovedTicket()
        defer { fixture.repo.remove() }
        let failing = FakeAgentRunner(implement: { _ in throw AgentError.timedOut(minutes: 30) })
        await #expect(throws: AgentError.timedOut(minutes: 30)) {
            _ = try await fixture.service(failing).implement(ticketID: fixture.ticket.id, repository: fixture.repo.config, tools: tools) { _ in }
        }
        #expect(try await fixture.db.runs(ticketID: fixture.ticket.id).last?.outcome == .timedOut)

        try await fixture.db.returnToApprovedPlan(ticketID: fixture.ticket.id)

        #expect(try await fixture.db.state(of: fixture.ticket.id) == .approved)
        _ = try await fixture.service(FakeAgentRunner()).implement(ticketID: fixture.ticket.id, repository: fixture.repo.config, tools: tools) { _ in }
        #expect(try await fixture.db.state(of: fixture.ticket.id) == .validating)
    }

    @Test func returningToApprovedNeedsAValidApproval() async throws {
        let db = try AppDatabase.inMemory()
        let ticket = Ticket.sample()
        try await db.recordSync([ticket], for: .jira)
        try await db.transition(ticketID: ticket.id, to: .selected, message: "")
        try await db.transition(ticketID: ticket.id, to: .cancelled, message: "")

        await #expect(throws: WorkflowError.implementationBlocked(.missingPlan)) {
            try await db.returnToApprovedPlan(ticketID: ticket.id)
        }
        #expect(try await db.state(of: ticket.id) == .cancelled)
    }

    @Test func missingWorktreeIsReported() async throws {
        let fixture = try await ApprovedTicket()
        defer { fixture.repo.remove() }
        try FileManager.default.removeItem(at: fixture.worktree)
        await #expect(throws: ImplementationError.worktreeMissing(fixture.workspace.worktreePath)) {
            _ = try await fixture.service(FakeAgentRunner()).implement(ticketID: fixture.ticket.id, repository: fixture.repo.config, tools: tools) { _ in }
        }
        #expect(try await fixture.db.state(of: fixture.ticket.id) == .approved)
    }
}

struct ImplementationRunnerTests {
    let worktree = "/Users/dev/DevPilot/worktrees/api/jira-plat-182"

    func request(commands: [String]) -> ImplementationRequest {
        ImplementationRequest(
            ticket: .sample(), workspace: .sample(worktree: worktree),
            plan: DecisionDocument(ticketID: Ticket.sample().id, version: 2, markdown: "# Plan", createdAt: Date()),
            allowedCommands: commands, commonGitDirectory: "/Users/dev/code/api/.git",
            tools: ToolEnvironment(path: "/opt/homebrew/bin", javaHome: "/jdk"), logURL: URL(filePath: "/tmp/x.jsonl")
        )
    }

    func runner() -> ClaudeCodeRunner {
        ClaudeCodeRunner(executable: URL(filePath: "/bin/claude"), model: nil, investigationTimeout: .seconds(1), implementationTimeout: .seconds(1))
    }

    func values(after flag: String, in arguments: [String]) -> [String] {
        guard let start = arguments.firstIndex(of: flag) else { return [] }
        return Array(arguments[(start + 1)...].prefix { !$0.hasPrefix("--") })
    }

    @Test func permissionsAreScopedToWorktreeAndApprovedCommands() {
        let arguments = runner().implementationArguments(request(commands: ["./mvnw", "git status"]))
        #expect(values(after: "--tools", in: arguments) == ["Read,Grep,Glob,Edit,Write,Bash"])
        #expect(values(after: "--allowedTools", in: arguments) == [
            "Read(/\(worktree)/**)", "Edit(/\(worktree)/**)", "Bash(./mvnw:*)", "Bash(git status:*)",
        ])
        let denied = values(after: "--disallowedTools", in: arguments)
        #expect(denied.contains("Edit(/\(worktree)/.git)"))
        #expect(denied.contains("Bash(git commit:*)"))
        #expect(denied.contains("Bash(git push:*)"))
        #expect(values(after: "--permission-mode", in: arguments) == ["dontAsk"])
        #expect(arguments.contains("--setting-sources"))
        #expect(!arguments.contains("--dangerously-skip-permissions"))
    }

    @Test func noCommandsMeansNoShell() {
        let arguments = runner().implementationArguments(request(commands: []))
        #expect(values(after: "--tools", in: arguments) == ["Read,Grep,Glob,Edit,Write"])
        #expect(!values(after: "--allowedTools", in: arguments).contains { $0.hasPrefix("Bash") })
    }

    @Test func sandboxSettingsProtectGitSecretsAndNetwork() throws {
        let arguments = runner().implementationArguments(request(commands: ["pnpm"]))
        let json = try #require(values(after: "--settings", in: arguments).first)
        let sandbox = try #require(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))["sandbox"])
        #expect(sandbox["enabled"] == .bool(true))
        #expect(sandbox["failIfUnavailable"] == .bool(true))
        #expect(sandbox["allowUnsandboxedCommands"] == .bool(false))
        #expect(sandbox["network"]?["allowedDomains"] == .array([]))
        let denyWrite = sandbox["filesystem"]?["denyWrite"]?.array?.compactMap(\.string) ?? []
        #expect(denyWrite.contains("/Users/dev/code/api/.git"))
        #expect(denyWrite.contains(worktree + "/.git"))
        let home = NSHomeDirectory()
        let denyRead = sandbox["filesystem"]?["denyRead"]?.array?.compactMap(\.string) ?? []
        #expect(denyRead.contains(home + "/.ssh"))
        #expect(denyRead.contains(home + "/.zshrc"))
        let allowWrite = sandbox["filesystem"]?["allowWrite"]?.array?.compactMap(\.string) ?? []
        #expect(allowWrite.contains(home + "/.m2"))
        #expect(allowWrite.contains(home + "/Library/pnpm"))
    }

    @Test func implementationOverFakeCLI() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "devpilot-impl-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = String(decoding: try JSONEncoder().encode(ImplementationReport.sample()), as: UTF8.self)
        let fake = try FakeClaude(body: """
            echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"\(directory.path)/Sources/A.swift"}}]}}'
            echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"./mvnw -q test"}}]}}'
            echo '{"type":"result","subtype":"success","is_error":false,"num_turns":9,"total_cost_usd":0.5,"structured_output":\(report)}'
            """)
        defer { fake.remove() }
        let runner = ClaudeCodeRunner(executable: fake.executable, model: nil, investigationTimeout: .seconds(10), implementationTimeout: .seconds(10))
        let progress = Mutex<[String]>([])
        let request = ImplementationRequest(
            ticket: .sample(), workspace: .sample(worktree: directory.path),
            plan: DecisionDocument(ticketID: Ticket.sample().id, version: 1, markdown: "# Approved plan text", createdAt: Date()),
            allowedCommands: ["./mvnw"], commonGitDirectory: "/x/.git",
            tools: ToolEnvironment(path: "/opt/tools/bin", javaHome: "/opt/jdk"), logURL: fake.directory.appending(path: "impl.jsonl")
        )

        let (parsed, stats) = try await runner.implement(request) { line in progress.withLock { $0.append(line) } }

        #expect(parsed == .sample())
        #expect(stats.numTurns == 9)
        #expect(progress.withLock { $0 } == ["Editing Sources/A.swift", "Running `./mvnw -q test`"])
        #expect(fake.recorded("stdin.txt").contains("# Approved plan text"))
        let environment = fake.recorded("env.txt")
        #expect(environment.contains("JAVA_HOME=/opt/jdk"))
        #expect(environment.contains("PATH=/opt/tools/bin:/usr/bin"))
        #expect(!environment.contains("ANTHROPIC_API_KEY"))
    }
}

struct BranchNamingTests {
    func ticket(_ provider: TicketProviderKind, _ id: String, _ type: TicketType) -> Ticket {
        Ticket(
            provider: provider, source: "acme", externalID: id, title: "T", description: "", status: "", assignee: nil,
            url: URL(string: "https://example.com")!, comments: [], acceptanceCriteria: [], fetchedAt: Date(), type: type
        )
    }

    @Test(arguments: [
        (TicketProviderKind.shortcut, "4211", TicketType.feature, "feat/sc-4211"),
        (.shortcut, "4230", .bug, "fix/sc-4230"),
        (.shortcut, "4300", .chore, "chore/sc-4300"),
        (.jira, "PLAT-182", .feature, "feat/PLAT-182"),
        (.jira, "MOB-77", .bug, "fix/MOB-77"),
        (.jira, "../x y", .feature, "feat/x-y"),
    ])
    func names(provider: TicketProviderKind, id: String, type: TicketType, expected: String) {
        #expect(GitWorktreeManager.branchName(for: ticket(provider, id, type)) == expected)
    }

    @Test(arguments: [
        ("Bug", TicketType.bug), ("Production Incident", .bug), ("Task", .chore), ("Sub-task", .chore),
        ("Story", .feature), ("Improvement", .feature), ("feature", .feature), ("chore", .chore), ("", .feature),
    ])
    func typeClassification(name: String, expected: TicketType) {
        #expect(TicketType(providerName: name) == expected)
    }

    @Test func providersReportTypes() async throws {
        let jira = JiraTicketProvider(
            siteURL: URL(string: "https://acme.atlassian.net")!, email: "a@b.c", apiToken: "t", acceptanceCriteriaField: nil,
            client: APIClient(http: MockHTTPClient { request in
                request.jsonBody?["nextPageToken"]?.string == "page-2-token" ? .fixture("jira-search-page2.json") : .fixture("jira-search-page1.json")
            }, sleep: SleepRecorder().sleep)
        )
        #expect(try await jira.assignedTickets().map(\.type) == [.feature, .bug])
        let db = try AppDatabase.inMemory()
        try await db.recordSync(try await jira.assignedTickets(), for: .jira)
        #expect(try await db.tickets().map(\.type).sorted { $0.rawValue < $1.rawValue } == [.bug, .feature])
    }
}

struct WorktreeInspectionTests {
    @Test func parsesPorcelainStatus() {
        let output = " M a.swift\0?? new file.txt\0R  new.swift\0old.swift\0D  gone.swift\0A  added.swift\0"
        #expect(GitWorktreeManager.parseStatus(output) == [
            ChangedFile(path: "a.swift", change: .modified),
            ChangedFile(path: "new file.txt", change: .untracked),
            ChangedFile(path: "new.swift", change: .renamed),
            ChangedFile(path: "gone.swift", change: .deleted),
            ChangedFile(path: "added.swift", change: .added),
        ])
    }

    @Test func headAndCommonDirectory() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        let workspace = try await repo.manager.prepareWorktree(for: .sample(), repository: repo.config)
        #expect(try await repo.manager.head(of: workspace.worktreePath) == workspace.baseCommit)
        let common = try await repo.manager.commonGitDirectory(of: workspace.worktreePath)
        #expect(GitWorktreeManager.realPath(common) == GitWorktreeManager.realPath(repo.repo.appending(path: ".git").path))
        #expect(try await repo.manager.changedFiles(in: workspace.worktreePath).isEmpty)
    }
}

struct CommandPresetTests {
    func directory(_ files: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "presets-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for file in files {
            FileManager.default.createFile(atPath: url.appending(path: file).path, contents: Data())
        }
        return url
    }

    @Test func mavenWrapperProject() throws {
        let url = try directory(["pom.xml", "mvnw"])
        defer { try? FileManager.default.removeItem(at: url) }
        let presets = CommandPresets.detect(repositoryAt: url.path)
        #expect(presets.setup.map(\.command) == ["./mvnw -B -q -DskipTests verify"])
        #expect(presets.agent.map(\.command) == ["./mvnw", "java"] + CommandPresets.gitInspection + CommandPresets.shellUtilities)
        #expect((presets.setup + presets.agent).allSatisfy { $0.isEnabled })
    }

    @Test func gradleProject() throws {
        let url = try directory(["build.gradle.kts", "gradlew"])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(CommandPresets.detect(repositoryAt: url.path).agent.map(\.command).prefix(2) == ["./gradlew", "java"])
    }

    @Test func pnpmAndNpmProjects() throws {
        let pnpm = try directory(["package.json", "pnpm-lock.yaml"])
        let npm = try directory(["package.json", "package-lock.json"])
        defer {
            try? FileManager.default.removeItem(at: pnpm)
            try? FileManager.default.removeItem(at: npm)
        }
        let p = CommandPresets.detect(repositoryAt: pnpm.path)
        #expect(p.setup.map(\.command) == ["pnpm install --frozen-lockfile"])
        #expect(p.agent.map(\.command) == ["pnpm", "npx", "node"] + CommandPresets.gitInspection + CommandPresets.shellUtilities)
        #expect(CommandPresets.detect(repositoryAt: npm.path).setup.map(\.command) == ["npm ci"])
    }

    @Test func monorepoWithJavaAndPnpmServices() throws {
        let url = try directory([])
        defer { try? FileManager.default.removeItem(at: url) }
        for (folder, files) in [
            "services/core": ["gradlew", "build.gradle"], "services/ui": ["package.json", "pnpm-lock.yaml"],
            "services/core/app": ["build.gradle"], "services/ui/node_modules/x": ["package.json"], "docs": ["package.json"],
        ] {
            let dir = url.appending(path: folder)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            files.forEach { FileManager.default.createFile(atPath: dir.appending(path: $0).path, contents: Data()) }
        }

        let presets = CommandPresets.detect(repositoryAt: url.path)

        #expect(CommandPresets.projectDirectories(in: url) == ["services/core", "services/ui"])
        #expect(presets.setup.map(\.command) == [
            "cd services/core && ./gradlew --no-daemon -q testClasses",
            "cd services/ui && pnpm install --frozen-lockfile",
        ])
        #expect(presets.agent.map(\.command) == ["cd", "./gradlew", "java", "pnpm", "npx", "node"] + CommandPresets.gitInspection + CommandPresets.shellUtilities)
    }

    @Test func oldRepositorySettingsDecodeWithoutCommands() throws {
        let json = #"{"id":"r","name":"API","path":"/a","baseBranch":"main"}"#
        let repository = try JSONDecoder().decode(RepositoryConfig.self, from: Data(json.utf8))
        #expect(repository.agentCommands.isEmpty && repository.setupCommands.isEmpty)
    }
}

struct ToolEnvironmentTests {
    @Test func buildsPathAndKeepsBaseClean() {
        let variables = ToolEnvironment(path: "/opt/homebrew/bin:/usr/bin:/sdk/java/bin", javaHome: "/sdk/java").variables(base: ["HOME": "/Users/x"])
        #expect(variables["PATH"] == "/opt/homebrew/bin:/usr/bin:/sdk/java/bin:/bin:/usr/sbin:/sbin")
        #expect(variables["JAVA_HOME"] == "/sdk/java")
        #expect(variables["HOME"] == "/Users/x")
        #expect(variables["CI"] == "true")
        #expect(variables["ANTHROPIC_API_KEY"] == nil)
    }

    @Test func parsesShellOutputDespiteNoise() {
        let output = "Welcome!\nsome rc noise\n__M__/a/bin:/usr/bin__M__/jdk__M__\n"
        #expect(ToolEnvironment.parse(output, marker: "__M__") == ToolEnvironment(path: "/a/bin:/usr/bin", javaHome: "/jdk"))
        #expect(ToolEnvironment.parse("nothing", marker: "__M__") == nil)
    }

    @Test func importsFromARealShell() async throws {
        let environment = try await ToolEnvironment.importFromLoginShell(shell: "/bin/sh")
        #expect(environment.path.contains("/usr/bin"))
    }
}

struct OrphanCleanupTests {
    @Test func killsLeftoverGroupOnlyWhenCommandMatches() async throws {
        let launched = Mutex<pid_t>(0)
        let task = Task {
            try await ProcessRunner.run(ProcessRequest(
                executable: URL(filePath: "/bin/sleep"), arguments: ["30"], workingDirectory: URL(filePath: "/"),
                environment: [:], timeout: .seconds(60), onLaunch: { pid in launched.withLock { $0 = pid } }
            ))
        }
        while launched.withLock({ $0 }) == 0 { try await Task.sleep(for: .milliseconds(20)) }
        let group = launched.withLock { $0 }

        #expect(await ProcessRunner.terminateOrphanedGroup(group, expectedCommand: "claude") == false)
        #expect(kill(group, 0) == 0, "an unrelated process must survive")

        #expect(await ProcessRunner.terminateOrphanedGroup(group, expectedCommand: "sleep"))
        let result = try await task.value
        #expect(result.termination == .signaled(SIGKILL))
    }
}

struct BlockedAndDiscardTests {
    let tools = ToolEnvironment(path: "", javaHome: "")

    @Test func blockedRunWithoutChangesFailsAndKeepsTheReport() async throws {
        let fixture = try await ApprovedTicket()
        defer { fixture.repo.remove() }
        let runner = FakeAgentRunner(implement: { _ in .sample(outcome: .blocked) })

        await #expect(throws: ImplementationError.blocked("Added retries.")) {
            _ = try await fixture.service(runner).implement(ticketID: fixture.ticket.id, repository: fixture.repo.config, tools: tools) { _ in }
        }

        #expect(try await fixture.db.state(of: fixture.ticket.id) == .failed)
        let run = try #require(try await fixture.db.runs(ticketID: fixture.ticket.id).last)
        #expect(run.outcome == .failed)
        #expect(run.implementation?.report.outcome == .blocked)
        #expect(run.errorMessage?.hasPrefix("Claude stopped without changing anything") == true)
    }

    @Test func validatingTicketsSurviveRecovery() async throws {
        let fixture = try await ApprovedTicket()
        defer { fixture.repo.remove() }
        _ = try await fixture.service(FakeAgentRunner()).implement(ticketID: fixture.ticket.id, repository: fixture.repo.config, tools: tools) { _ in }

        _ = try await fixture.db.failInterruptedRuns(message: "Interrupted")

        #expect(try await fixture.db.state(of: fixture.ticket.id) == .validating)
    }

    @Test func discardRemovesCleanWorktreeAndUnusedBranch() async throws {
        let fixture = try await ApprovedTicket()
        defer { fixture.repo.remove() }

        let branchDeleted = try await fixture.repo.manager.removeWorktree(fixture.workspace)
        try await fixture.db.deleteWorkspace(ticketID: fixture.ticket.id)

        #expect(branchDeleted)
        #expect(!FileManager.default.fileExists(atPath: fixture.workspace.worktreePath))
        #expect(try await fixture.repo.git("branch", "--list", fixture.workspace.branch).isEmpty)
        #expect(try await fixture.db.workspace(ticketID: fixture.ticket.id) == nil)
    }

    @Test func discardRefusesUncommittedWork() async throws {
        let fixture = try await ApprovedTicket()
        defer { fixture.repo.remove() }
        try "work in progress\n".write(to: fixture.worktree.appending(path: "notes.txt"), atomically: true, encoding: .utf8)

        await #expect(throws: WorkspaceError.self) {
            try await fixture.repo.manager.removeWorktree(fixture.workspace)
        }
        #expect(FileManager.default.fileExists(atPath: fixture.worktree.appending(path: "notes.txt").path))
    }

    @Test func discardKeepsBranchWithCommits() async throws {
        let fixture = try await ApprovedTicket()
        defer { fixture.repo.remove() }
        try "done\n".write(to: fixture.worktree.appending(path: "feature.txt"), atomically: true, encoding: .utf8)
        try await fixture.repo.git("add", "-A", in: fixture.worktree)
        try await fixture.repo.git("-c", "user.email=a@b", "-c", "user.name=u", "commit", "-qm", "feature", in: fixture.worktree)

        let branchDeleted = try await fixture.repo.manager.removeWorktree(fixture.workspace)

        #expect(!branchDeleted)
        #expect(!(try await fixture.repo.git("branch", "--list", fixture.workspace.branch).isEmpty))
    }
}
