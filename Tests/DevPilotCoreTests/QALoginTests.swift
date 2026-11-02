import Foundation
import Testing
@testable import DevPilotCore

struct LoginConfigTests {
    @Test func secretNamesInOrderWithoutDuplicates() {
        var config = LoginConfig()
        config.script = """
            await page.fill('#u', secret('qa_username'));
            await page.fill('#p', secret( "qa_password" ));
            await page.fill('#again', secret(`qa_username`));
            """
        #expect(config.secretNames == ["qa_username", "qa_password"])
    }

    @Test func decodesOlderSettingsWithDefaults() throws {
        let config = try JSONDecoder().decode(LoginConfig.self, from: Data("{\"script\":\"x\"}".utf8))
        #expect(config.script == "x" && !config.isEnabled && config.loginPath == "/login" && config.checkPath == "/")
        let repository = try JSONDecoder().decode(
            RepositoryConfig.self, from: Data(#"{"id":"r","name":"n","path":"/p","baseBranch":"main"}"#.utf8)
        )
        #expect(repository.qa == QAConfig())
    }

    @Test func redactsSecretValuesLongestFirst() {
        let text = "fill(\"hunter22\") as alice@example.com; hunter2 left"
        let redacted = LoginRunner.redact(text, secrets: ["qa_password": "hunter2", "other": "hunter22", "qa_username": "alice@example.com", "x": "ab"])
        #expect(redacted == "fill(\"•••\") as •••; ••• left")
    }

    @Test func clerkFrontendWithSignInRoute() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "devpilot-login-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let frontend = root.appending(path: "frontend/src", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: frontend, withIntermediateDirectories: true)
        try "source 'https://rubygems.org'\n".write(to: root.appending(path: "Gemfile"), atomically: true, encoding: .utf8)
        try #"{"scripts":{"dev":"vite"},"dependencies":{"@clerk/clerk-react":"^5"}}"#
            .write(to: root.appending(path: "frontend/package.json"), atomically: true, encoding: .utf8)
        try "navigate('/sign-in'); <Route path=\"/sign-in\" />; if (x) navigate('/login')"
            .write(to: frontend.appending(path: "routes.tsx"), atomically: true, encoding: .utf8)
        // Its own form on top of Clerk: the form runs the app's after-sign-in steps.
        var config = LoginPresets.detect(repositoryAt: root.path)
        #expect(config.loginPath == "/sign-in" && config.checkPath == "/")
        #expect(config.script.contains("press('Enter')"))

        try "import { SignIn } from '@clerk/clerk-react';\nexport default () => <SignIn />;\nnavigate('/dashboard')"
            .write(to: frontend.appending(path: "SignInPage.tsx"), atomically: true, encoding: .utf8)
        config = LoginPresets.detect(repositoryAt: root.path)
        #expect(config.script.contains("window.Clerk.client.signIn.create"))
        #expect(config.checkPath == "/dashboard")
        #expect(config.secretNames == [LoginPresets.usernameSecret, LoginPresets.passwordSecret])
    }

    @Test func previousFormPresetIsRecognised() {
        let old = """
            await page.goto('/login');
            await page.getByLabel(/email|username/i).first().fill(secret('qa_username'));
            const password = page.getByLabel(/password/i).first();
            await password.fill(secret('qa_password'));
            await password.press('Enter');
            await page.waitForURL((url) => url.origin === new URL(baseURL).origin && !url.pathname.startsWith('/login'));
            """
        #expect(LoginPresets.previousForm(loginPath: "/login") == old)
        #expect(LoginPresets.form(loginPath: "/login").contains("networkidle"))
    }

    @Test func plainFrontendGetsAFormLogin() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "devpilot-login-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try #"{"scripts":{"dev":"vite"}}"#.write(to: root.appending(path: "package.json"), atomically: true, encoding: .utf8)
        let config = LoginPresets.detect(repositoryAt: root.path)
        #expect(config.loginPath == "/login")
        #expect(config.script.contains("getByLabel(/password/i)") && !config.script.contains("click"))
    }

    static let node = ["/opt/homebrew/bin/node", "/usr/local/bin/node"].first { FileManager.default.isExecutableFile(atPath: $0) }

    @Test(.enabled(if: node != nil)) func harnessIsValidJavaScript() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "devpilot-harness-\(UUID().uuidString).mjs")
        defer { try? FileManager.default.removeItem(at: url) }
        try LoginRunner.harness.write(to: url, atomically: true, encoding: .utf8)
        let result = try await ProcessRunner.run(ProcessRequest(
            executable: URL(filePath: Self.node!), arguments: ["--check", url.path],
            workingDirectory: FileManager.default.temporaryDirectory, environment: [:], timeout: .seconds(30)
        ))
        #expect(result.succeeded, "\(result.stderrText)")
    }

    @Test func refusesWithoutTools() async throws {
        let empty = QATools(directory: FileManager.default.temporaryDirectory.appending(path: "devpilot-none-\(UUID().uuidString)"))
        var config = LoginConfig()
        config.script = LoginPresets.form(loginPath: "/login")
        let output = FileManager.default.temporaryDirectory.appending(path: "devpilot-out-\(UUID().uuidString)")
        await #expect(throws: LoginError.toolsNotInstalled) {
            _ = try await LoginRunner.signIn(config: config, baseURL: "http://localhost:1", secrets: [:], qaTools: empty,
                                             outputDirectory: output, tools: ToolEnvironment(path: "", javaHome: ""))
        }
    }
}

/// Signs in to a small local site with real Playwright. Needs QA tools: set DEVPILOT_QA_TOOLS to
/// a folder with node_modules containing playwright.
struct LiveLoginTests {
    static let toolsPath = ProcessInfo.processInfo.environment["DEVPILOT_QA_TOOLS"]

    struct Site {
        let root: URL
        let process: BackgroundProcess
        let baseURL: String

        /// `/login/` checks the password ("right-pass"), then keeps the session in `storage`
        /// ("localStorage" is saved with the session; "sessionStorage" is not).
        static func start(storage: String = "localStorage") async throws -> Site {
            let root = FileManager.default.temporaryDirectory.appending(path: "devpilot-site-\(UUID().uuidString)", directoryHint: .isDirectory)
            for folder in ["login", "app"] {
                try FileManager.default.createDirectory(at: root.appending(path: folder), withIntermediateDirectories: true)
            }
            try """
                <form id="f"><label>Email <input name="email"></label><label>Password <input name="password" type="password"></label>
                <button>Sign in</button></form><p id="error"></p>
                <script>
                document.getElementById('f').onsubmit = (event) => {
                  event.preventDefault();
                  if (event.target.password.value !== 'right-pass') { document.getElementById('error').textContent = 'Wrong password'; return; }
                  \(storage).setItem('session', event.target.email.value);
                  location.href = '/app/';
                };
                </script>
                """.write(to: root.appending(path: "login/index.html"), atomically: true, encoding: .utf8)
            try """
                <h1 id="who"></h1>
                <script>
                const who = localStorage.getItem('session') || sessionStorage.getItem('session');
                if (!who) location.href = '/login/'; else document.getElementById('who').textContent = 'Welcome ' + who;
                </script>
                """.write(to: root.appending(path: "app/index.html"), atomically: true, encoding: .utf8)
            let port = try LocalEnvironment.freePorts(count: 1)[0]
            let process = try ProcessRunner.start(
                executable: URL(filePath: "/usr/bin/python3"), arguments: ["-m", "http.server", String(port), "--bind", "127.0.0.1"],
                workingDirectory: root, environment: ["PATH": ToolEnvironment.systemPath], logURL: root.appending(path: "server.log")
            )
            for _ in 0..<50 where !LocalEnvironment.isPortOpen(port) { try await Task.sleep(for: .milliseconds(100)) }
            return Site(root: root, process: process, baseURL: "http://127.0.0.1:\(port)")
        }

        func stop() async {
            await process.terminate()
            try? FileManager.default.removeItem(at: root)
        }
    }

    func signIn(_ site: Site, password: String, checkPath: String = "/app/") async throws -> (LoginResult, URL) {
        var config = LoginConfig()
        config.loginPath = "/login"
        config.checkPath = checkPath
        config.timeoutSeconds = 5
        config.script = LoginPresets.form(loginPath: "/login/")
        let output = site.root.appending(path: "out", directoryHint: .isDirectory)
        let tools = try await ToolEnvironment.importFromLoginShell()
        let result = try await LoginRunner.signIn(
            config: config, baseURL: site.baseURL, secrets: ["qa_username": "qa@example.com", "qa_password": password],
            qaTools: QATools(directory: URL(filePath: Self.toolsPath!)), outputDirectory: output, tools: tools
        )
        return (result, output)
    }

    @Test(.enabled(if: toolsPath != nil)) func savesAWorkingSession() async throws {
        let site = try await Site.start()
        defer { Task { await site.stop() } }
        let (result, _) = try await signIn(site, password: "right-pass")
        #expect(result.finalURL.hasSuffix("/app/"))
        #expect(FileManager.default.fileExists(atPath: result.screenshotPath))
        let state = try String(contentsOf: URL(filePath: result.storageStatePath), encoding: .utf8)
        #expect(state.contains("qa@example.com"))
        await site.stop()
    }

    @Test(.enabled(if: toolsPath != nil)) func wrongPasswordFailsWithScreenshotAndNoSecretsInTheError() async throws {
        let site = try await Site.start()
        defer { Task { await site.stop() } }
        do {
            _ = try await signIn(site, password: "wrong-pass")
            Issue.record("expected a failure")
        } catch let error as LoginError {
            let message = error.localizedDescription
            #expect(!message.contains("wrong-pass") && !message.contains("qa@example.com"))
            #expect(error.screenshotPath.map { FileManager.default.fileExists(atPath: $0) } == true)
            let log = try String(contentsOf: site.root.appending(path: "out/login.log"), encoding: .utf8)
            #expect(!log.contains("wrong-pass") && !log.contains("qa@example.com"))
            #expect(!FileManager.default.fileExists(atPath: site.root.appending(path: "out/private/storage-state.json").path))
        }
        await site.stop()
    }

    @Test(.enabled(if: toolsPath != nil)) func checkPageThatNeedsNoSignInIsRejected() async throws {
        let site = try await Site.start()
        defer { Task { await site.stop() } }
        await #expect {
            _ = try await signIn(site, password: "right-pass", checkPath: "/")
        } throws: { error in
            (error as? LoginError)?.localizedDescription.contains("opens without signing in") == true
        }
        await site.stop()
    }

    @Test(.enabled(if: toolsPath != nil)) func sessionThatIsNotSavedIsReported() async throws {
        let site = try await Site.start(storage: "sessionStorage")
        defer { Task { await site.stop() } }
        await #expect {
            _ = try await signIn(site, password: "right-pass")
        } throws: { error in
            (error as? LoginError)?.localizedDescription.contains("the session was not kept") == true
        }
        await site.stop()
    }
}
