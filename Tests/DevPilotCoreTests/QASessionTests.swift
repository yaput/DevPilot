import Foundation
import Testing
@testable import DevPilotCore

struct QAAgentSetupTests {
    func request(root: String = "/tmp/qa") -> QARequest {
        QARequest(
            ticket: .sample(), workspace: .sample(worktree: "/w/t"), plan: nil, changedFiles: ["app/x.rb"],
            appURL: "http://localhost:5000", signedIn: true, serviceLogs: [("api", "\(root)/run/api.log")],
            logDirectory: "\(root)/run", excludedDirectory: "\(root)/run/qa-login", mcpConfigPath: "\(root)/mcp.json",
            sessionDirectory: "\(root)/session", timeLimitMinutes: 10, logURL: URL(filePath: "\(root)/agent.jsonl")
        )
    }

    @Test func browserToolsAreAnExplicitListAndCodeExecutionIsDenied() {
        let runner = ClaudeCodeRunner(executable: URL(filePath: "/bin/claude"), model: nil, investigationTimeout: .seconds(1), implementationTimeout: .seconds(1))
        let arguments = runner.qaArguments(request())
        func values(after flag: String) -> [String] {
            guard let start = arguments.firstIndex(of: flag) else { return [] }
            return Array(arguments[(start + 1)...].prefix { !$0.hasPrefix("--") })
        }
        #expect(arguments[arguments.firstIndex(of: "--mcp-config")! + 1] == "/tmp/qa/mcp.json")
        #expect(arguments.contains("--strict-mcp-config"))
        #expect(values(after: "--tools") == ["Read,Grep,Glob"])
        let allowed = values(after: "--allowedTools")
        #expect(allowed.contains("Read(//w/t/**)") && allowed.contains("Read(//tmp/qa/run/**)"))
        #expect(allowed.contains("mcp__playwright__browser_click"))
        #expect(!allowed.contains { $0.contains("run_code") || $0.contains("file_upload") || $0.contains("storage_state") })
        #expect(!allowed.contains("mcp__playwright"), "never the whole server")
        #expect(values(after: "--disallowedTools") == ["Read(//tmp/qa/run/qa-login/**)", "mcp__playwright__browser_run_code_unsafe"])
    }

    @Test func mcpConfigLoadsTheSessionAndLimitsOrigins() throws {
        let session = FileManager.default.temporaryDirectory.appending(path: "devpilot-qa-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: session) }
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let url = try QAService.writeMCPConfig(
            session: session, qaTools: QATools(directory: URL(filePath: "/qa-tools")), tools: ToolEnvironment(path: "/opt/bin", javaHome: ""),
            storageStatePath: "/state/session.json", allowedOrigins: ["http://localhost:1"]
        )
        let mcp = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        let args = mcp["mcpServers"]?["playwright"]?["args"]?.array?.compactMap(\.string) ?? []
        #expect(args.contains(session.path) && args.contains("/qa-tools/node_modules/@playwright/mcp/cli.js"))
        let playwright = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: session.appending(path: "playwright-mcp.json")))
        #expect(playwright["browser"]?["isolated"] == .bool(true))
        #expect(playwright["browser"]?["contextOptions"]?["storageState"]?.string == "/state/session.json")
        #expect(playwright["network"]?["allowedOrigins"]?.array?.compactMap(\.string) == ["http://localhost:1"])
    }

    @Test func allowedOriginsAddTheRunsPorts() {
        let run = LocalRunStatus(
            runID: "r", ticketID: "t", phase: .running, database: nil, appURL: "http://localhost:6000",
            services: [.init(name: "web", port: 6000, state: .ready, logPath: "/l"), .init(name: "worker", port: nil, state: .running, logPath: "/w")],
            logDirectory: "/l"
        )
        let signIn = LoginResult(storageStatePath: "/s", screenshotPath: "/p", finalURL: "", origins: ["https://clerk.example.com", "http://localhost:6000"])
        #expect(QAService.allowedOrigins(signIn: signIn, localRun: run) == ["http://127.0.0.1:6000", "http://localhost:6000", "https://clerk.example.com"])
    }

    @Test func changedFilesFromADiff() {
        let diff = "diff --git a/app/a.rb b/app/a.rb\n+x\ndiff --git a/old.ts b/new.ts\n-y\ndiff --git a/app/a.rb b/app/a.rb\n"
        #expect(QAService.changedFiles(inDiff: diff) == ["app/a.rb", "new.ts"])
    }

    @Test func replayStatusFromAttempts() {
        func attempt(_ reproduced: Bool?) -> QAReplayResult.Attempt { .init(reproduced: reproduced, message: "", failedStep: 0) }
        #expect(QAReplayResult.status(of: [attempt(true), attempt(true)]) == .confirmed)
        #expect(QAReplayResult.status(of: [attempt(true), attempt(false)]) == .flaky)
        #expect(QAReplayResult.status(of: [attempt(true), attempt(nil)]) == .flaky)
        #expect(QAReplayResult.status(of: [attempt(false), attempt(nil)]) == .notReproduced)
        #expect(QAReplayResult.status(of: [attempt(nil), attempt(nil)]) == .couldNotReplay)
    }

    @Test func tidyFixesCommonSlips() {
        let steps = QAStep.tidy([
            QAStep(action: .goto),
            QAStep(action: .fill, by: "label", name: "Display name", value: "x"),
            QAStep(action: .click, by: "role", selector: "button", name: "Save"),
        ], pageURL: "http://127.0.0.1:5000/profile/?tab=1")
        #expect(steps[0].value == "/profile/?tab=1")
        #expect(steps[1].selector == "Display name" && steps[1].name.isEmpty)
        #expect(steps[2].name == "Save")
        #expect(QAStep.tidy([QAStep(action: .goto)], pageURL: "")[0].value == "/")
    }

    @Test func schemaListsEveryStepAction() throws {
        let schema = try JSONDecoder().decode(JSONValue.self, from: Data(QAPrompt.schema.utf8))
        let actions = schema["properties"]?["findings"]?["items"]?["properties"]?["reproduction"]?["items"]?["properties"]?["action"]?["enum"]?
            .array?.compactMap(\.string)
        #expect(actions == QAStep.Action.allCases.map(\.rawValue))
    }
}

/// A small app with a planted bug: saving a name containing "&" fails.
struct BuggyApp {
    let root: URL
    let process: BackgroundProcess
    let baseURL: String

    static func start() async throws -> BuggyApp {
        let root = FileManager.default.temporaryDirectory.appending(path: "devpilot-buggy-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root.appending(path: "profile"), withIntermediateDirectories: true)
        try """
            <!doctype html><title>Acme</title><h1>Acme</h1><a href="/profile/">Profile</a>
            """.write(to: root.appending(path: "index.html"), atomically: true, encoding: .utf8)
        try """
            <!doctype html><title>Profile</title><h1>Profile</h1>
            <form id="f"><label>Display name <input name="name"></label><button>Save</button></form>
            <p id="status" role="status"></p>
            <script>
            document.getElementById('f').onsubmit = (event) => {
              event.preventDefault();
              const name = event.target.name.value;
              const status = document.getElementById('status');
              if (!name.trim()) { status.textContent = 'Name is required'; return; }
              if (name.includes('&')) { console.error('TypeError: cannot encode name'); status.textContent = 'Something went wrong'; return; }
              status.textContent = 'Saved ' + name;
            };
            </script>
            """.write(to: root.appending(path: "profile/index.html"), atomically: true, encoding: .utf8)
        let port = try LocalEnvironment.freePorts(count: 1)[0]
        let process = try ProcessRunner.start(
            executable: URL(filePath: "/usr/bin/python3"), arguments: ["-m", "http.server", String(port), "--bind", "127.0.0.1"],
            workingDirectory: root, environment: ["PATH": ToolEnvironment.systemPath], logURL: root.appending(path: "server.log")
        )
        for _ in 0..<50 where !LocalEnvironment.isPortOpen(port) { try await Task.sleep(for: .milliseconds(100)) }
        return BuggyApp(root: root, process: process, baseURL: "http://127.0.0.1:\(port)")
    }

    func stop() async {
        await process.terminate()
        try? FileManager.default.removeItem(at: root)
    }
}

/// Real Playwright; set DEVPILOT_QA_TOOLS to a folder with node_modules containing playwright.
struct LiveReplayTests {
    static let toolsPath = ProcessInfo.processInfo.environment["DEVPILOT_QA_TOOLS"]

    func replay(_ app: BuggyApp, _ steps: [QAStep]) async throws -> QAReplayResult {
        try await QAReplayer.replay(
            steps, baseURL: app.baseURL, storageStatePath: nil, qaTools: QATools(directory: URL(filePath: Self.toolsPath!)),
            outputDirectory: app.root.appending(path: "replay-\(UUID().uuidString)"), tools: try await ToolEnvironment.importFromLoginShell()
        )
    }

    static func save(_ name: String) -> [QAStep] {
        [
            QAStep(action: .goto, value: "/profile/"),
            QAStep(action: .fill, by: "label", selector: "Display name", value: name),
            QAStep(action: .click, by: "role", selector: "button", name: "Save"),
            QAStep(action: .expectText, by: "role", selector: "status", value: "Saved"),
            QAStep(action: .expectNoConsoleErrors),
        ]
    }

    @Test(.enabled(if: toolsPath != nil)) func plantedBugIsConfirmedWithVideoAndScreenshot() async throws {
        let app = try await BuggyApp.start()
        defer { Task { await app.stop() } }
        let result = try await replay(app, Self.save("Tom & Jerry"))
        #expect(result.status == .confirmed)
        #expect(result.attempts.count == 2)
        #expect(result.attempts.allSatisfy { $0.failedStep == 4 && $0.message.contains("does not show \"Saved\"") })
        for attempt in result.attempts {
            #expect(attempt.video.map { FileManager.default.fileExists(atPath: $0) } == true)
            #expect(attempt.screenshot.map { FileManager.default.fileExists(atPath: $0) } == true)
        }
        await app.stop()
    }

    @Test(.enabled(if: toolsPath != nil)) func workingBehaviourIsNotReproducedAndBrokenStepsAreSaidSo() async throws {
        let app = try await BuggyApp.start()
        defer { Task { await app.stop() } }
        let working = try await replay(app, Self.save("Tom"))
        #expect(working.status == .notReproduced, "\(working.attempts.map(\.message))")

        var missing = Self.save("Tom")
        missing[2] = QAStep(action: .click, by: "role", selector: "button", name: "Publish")
        let broken = try await replay(app, missing)
        #expect(broken.status == .couldNotReplay)
        #expect(broken.attempts.first?.message.contains("step 3 (click) could not run") == true)

        let outside = try await replay(app, [QAStep(action: .goto, value: "https://example.com/")])
        #expect(outside.attempts.first?.message.contains("outside the app") == true)
        await app.stop()
    }
}

/// A real QA session: Claude with DevPilot's Playwright MCP against the planted bug. Opt-in, as
/// it uses your Claude login and quota, and needs QA tools (DEVPILOT_QA_TOOLS or DevPilot's own):
///
///     DEVPILOT_LIVE_CLAUDE=1 swift test --filter LiveQAAgentTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DEVPILOT_LIVE_CLAUDE"] == "1"))
struct LiveQAAgentTests {
    @Test(.timeLimit(.minutes(15)))
    func findsAndConfirmsThePlantedBug() async throws {
        let qaTools = QATools(directory: ProcessInfo.processInfo.environment["DEVPILOT_QA_TOOLS"].map { URL(filePath: $0) }
            ?? AppDatabase.defaultDirectory.appending(path: "qa-tools", directoryHint: .isDirectory))
        try #require(qaTools.isInstalled, "QA tools not installed")
        let app = try await BuggyApp.start()
        defer { Task { await app.stop() } }
        let worktree = app.root.appending(path: "worktree", directoryHint: .isDirectory)
        let session = app.root.appending(path: "session", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let tools = try await ToolEnvironment.importFromLoginShell()
        let mcp = try QAService.writeMCPConfig(session: session, qaTools: qaTools, tools: tools, storageStatePath: nil, allowedOrigins: nil)
        let ticket = Ticket.sample("ACME-7", description: """
            Profile page (/profile/): users can set their display name and press Save, which shows "Saved <name>".
            Acceptance: any display name, including ones with punctuation such as "&", "'" or emoji, saves successfully.
            """)
        let request = QARequest(
            ticket: ticket, workspace: .sample(ticketID: ticket.id, worktree: worktree.path), plan: nil, changedFiles: ["profile/index.html"],
            appURL: app.baseURL, signedIn: false, serviceLogs: [("web", app.root.appending(path: "server.log").path)],
            logDirectory: app.root.path, excludedDirectory: session.path, mcpConfigPath: mcp.path, sessionDirectory: session.path,
            timeLimitMinutes: 5, logURL: session.appending(path: "agent.jsonl")
        )
        let executable = try #require(ClaudeCLI.resolve(configuredPath: ""), "claude CLI not found")
        let runner = ClaudeCodeRunner(executable: executable, model: "sonnet", investigationTimeout: .seconds(1), implementationTimeout: .seconds(1))
        let (report, _) = try await runner.exploreQA(request) { print("QA progress: \($0)") }

        print("QA summary: \(report.summary)")
        for finding in report.findings {
            let replay = try await QAReplayer.replay(
                QAStep.tidy(finding.reproduction, pageURL: finding.pageURL), baseURL: app.baseURL, storageStatePath: nil, qaTools: qaTools,
                outputDirectory: session.appending(path: "replay-\(UUID().uuidString)"), tools: tools
            )
            print("QA finding [\(replay.status.rawValue)] \(finding.severity.rawValue): \(finding.title)")
            print("   steps: \(finding.reproduction.map(\.summary).joined(separator: " | "))")
            print("   replay: \(replay.attempts.map(\.message))")
        }
        let used = (try? String(contentsOf: session.appending(path: "agent.jsonl"), encoding: .utf8)) ?? ""
        print("QA browser tools used: \(Set(used.matches(of: /"name":"mcp__playwright__(browser_[a-z_]+)"/).map { String($0.1) }).sorted())")
        let denials = used.split(separator: "\n").filter { $0.contains("\"is_error\":true") && ($0.contains("permission") || $0.contains("not allowed")) }
        print("QA denied tool calls: \(denials.count)")
        for denial in denials.prefix(5) { print("QA denial: \(denial.prefix(300))") }
        #expect(report.findings.contains { $0.title.contains("&") || $0.actual.contains("Something went wrong") })
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: worktree.path)) ?? []
        #expect(leftovers.isEmpty, "the QA session must not write into the worktree: \(leftovers)")
        await app.stop()
    }
}
