import Foundation

/// Per-repository settings for QA sessions against a local run.
public struct QAConfig: Codable, Sendable, Hashable {
    public var login = LoginConfig()
    /// How long the QA agent explores before it must report.
    public var timeLimitMinutes = 15

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        login = try container.decodeIfPresent(LoginConfig.self, forKey: .login) ?? LoginConfig()
        timeLimitMinutes = try container.decodeIfPresent(Int.self, forKey: .timeLimitMinutes) ?? timeLimitMinutes
    }
}

/// How DevPilot signs in to the locally running app before a QA session. The script is
/// DevPilot's (never the repository's) and refers to credentials only as `secret("NAME")`: the
/// values come from the Keychain, reach only the login process, and no agent ever sees them.
public struct LoginConfig: Codable, Sendable, Hashable {
    public var isEnabled = false
    /// The sign-in page. Opening `checkPath` with the saved session must not end up here.
    public var loginPath = "/login"
    /// A page that needs a session, opened with the saved session to prove it works.
    public var checkPath = "/"
    /// The body of `async ({ page, context, secret, baseURL }) => { … }` (Playwright).
    public var script = ""
    /// Default timeout for each Playwright action.
    public var timeoutSeconds = 30

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? isEnabled
        loginPath = try container.decodeIfPresent(String.self, forKey: .loginPath) ?? loginPath
        checkPath = try container.decodeIfPresent(String.self, forKey: .checkPath) ?? checkPath
        script = try container.decodeIfPresent(String.self, forKey: .script) ?? script
        timeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? timeoutSeconds
    }

    /// Secret names the script uses, in order of first use.
    public var secretNames: [String] {
        var names: [String] = []
        for match in script.matches(of: /secret\(\s*["'`]([A-Za-z0-9_]+)["'`]\s*\)/) where !names.contains(String(match.1)) {
            names.append(String(match.1))
        }
        return names
    }
}

public enum LoginPresets {
    public static let usernameSecret = "qa_username"
    public static let passwordSecret = "qa_password"

    /// An email/username and password form, submitted with Enter (button labels vary, and
    /// "Continue with Google" must never be clicked) once the page has settled: a freshly started
    /// dev server is slow, and many sign-in forms ignore a submit until their auth library loads.
    /// Done once back on the app, off the sign-in page.
    public static func form(loginPath: String) -> String {
        """
        await page.goto('\(loginPath)');
        await page.waitForLoadState('networkidle', { timeout: 15000 }).catch(() => {});
        await page.getByLabel(/email|username/i).first().fill(secret('\(usernameSecret)'));
        const password = page.getByLabel(/password/i).first();
        await password.fill(secret('\(passwordSecret)'));
        await password.press('Enter');
        await page.waitForURL((url) => url.origin === new URL(baseURL).origin && !url.pathname.startsWith('\(loginPath)'));
        """
    }

    /// Clerk's password sign-in through its browser API, as Clerk's own testing helpers do; no
    /// dependence on the sign-in form's markup.
    public static func clerk(loginPath: String) -> String {
        """
        await page.goto('\(loginPath)');
        await page.waitForFunction(() => window.Clerk?.loaded);
        await page.evaluate(async ({ identifier, password }) => {
          const attempt = await window.Clerk.client.signIn.create({ strategy: 'password', identifier, password });
          if (attempt.status !== 'complete') throw new Error(`Clerk sign-in needs more steps: ${attempt.status}`);
          await window.Clerk.setActive({ session: attempt.createdSessionId });
        }, { identifier: secret('\(usernameSecret)'), password: secret('\(passwordSecret)') });
        """
    }

    /// The form preset as written by earlier versions, so it can be updated where it was not edited.
    public static func previousForm(loginPath: String) -> String {
        form(loginPath: loginPath).replacingOccurrences(of: "await page.waitForLoadState('networkidle', { timeout: 15000 }).catch(() => {});\n", with: "")
    }

    /// Clerk when a front end renders Clerk's own `<SignIn>` (two steps, so no plain form),
    /// otherwise the app's form, which also runs the app's own after-sign-in steps. The login path
    /// is the most common of `/login` and `/sign-in` in the front-end sources.
    public static func detect(repositoryAt path: String) -> LoginConfig {
        let root = URL(filePath: path, directoryHint: .isDirectory)
        let nodeProjects = CommandPresets.projectDirectories(in: root).filter {
            FileManager.default.fileExists(atPath: root.appending(path: $0.isEmpty ? "package.json" : "\($0)/package.json").path)
        }
        var config = LoginConfig()
        let usesClerk = nodeProjects.contains { project in
            let text = (try? String(contentsOf: root.appending(path: project.isEmpty ? "package.json" : "\(project)/package.json"), encoding: .utf8)) ?? ""
            return text.contains("\"@clerk/")
        }
        let sources = scanSources(in: nodeProjects.map { root.appending(path: $0, directoryHint: .isDirectory) })
        config.loginPath = sources.loginPath ?? "/login"
        if sources.mentionsDashboard { config.checkPath = "/dashboard" }
        config.script = usesClerk && sources.rendersClerkSignIn ? clerk(loginPath: config.loginPath) : form(loginPath: config.loginPath)
        return config
    }

    static func scanSources(in directories: [URL]) -> (loginPath: String?, rendersClerkSignIn: Bool, mentionsDashboard: Bool) {
        var counts: [String: Int] = [:]
        var rendersClerkSignIn = false
        var mentionsDashboard = false
        var scanned = 0
        for directory in directories {
            guard let files = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
            ) else { continue }
            for case let file as URL in files {
                if ["node_modules", "dist", "build"].contains(file.lastPathComponent) {
                    files.skipDescendants()
                    continue
                }
                guard ["ts", "tsx", "js", "jsx", "svelte", "vue"].contains(file.pathExtension),
                      (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 < 200_000,
                      let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                for path in ["/login", "/sign-in", "/signin"] {
                    counts[path, default: 0] += text.components(separatedBy: "'\(path)'").count - 1
                        + text.components(separatedBy: "\"\(path)\"").count - 1
                }
                rendersClerkSignIn = rendersClerkSignIn || (text.contains("<SignIn") && text.contains("@clerk/"))
                mentionsDashboard = mentionsDashboard || text.contains("'/dashboard") || text.contains("\"/dashboard")
                scanned += 1
                if scanned >= 5000 { break }
            }
        }
        return (counts.filter { $0.value > 0 }.max { $0.value < $1.value }?.key, rendersClerkSignIn, mentionsDashboard)
    }
}

/// DevPilot's own Playwright install (with Playwright MCP for QA agents), kept apart from any
/// repository. Installed once, on request, at a pinned version.
public struct QATools: Sendable {
    public static let mcpVersion = "0.0.83"
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public var isInstalled: Bool {
        let modules = directory.appending(path: "node_modules")
        return ["playwright/package.json", "@playwright/mcp/package.json"].allSatisfy {
            FileManager.default.fileExists(atPath: modules.appending(path: $0).path)
        }
    }

    /// Installed Google Chrome is used when present, so no browser download is needed.
    public static var browserChannel: String? {
        FileManager.default.fileExists(atPath: "/Applications/Google Chrome.app") ? "chrome" : nil
    }

    /// `npm install` of the pinned packages (install scripts off); without Chrome, also
    /// Playwright's own Chromium.
    public func install(tools: ToolEnvironment) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = """
            {
              "name": "devpilot-qa-tools",
              "private": true,
              "description": "Installed by DevPilot for QA sessions.",
              "dependencies": { "@playwright/mcp": "\(Self.mcpVersion)" }
            }

            """
        try manifest.write(to: directory.appending(path: "package.json"), atomically: true, encoding: .utf8)
        var commands = [["npm", "install", "--no-fund", "--no-audit", "--ignore-scripts"]]
        if Self.browserChannel == nil {
            commands.append(["node", "node_modules/playwright/cli.js", "install", "chromium"])
        }
        for command in commands {
            let result = try await ProcessRunner.run(ProcessRequest(
                executable: URL(filePath: "/usr/bin/env"), arguments: command, workingDirectory: directory,
                environment: tools.variables(base: ClaudeCodeRunner.environment()), timeout: .seconds(900)
            ))
            guard result.succeeded else {
                let detail = (result.stderrText.isEmpty ? result.stdoutText : result.stderrText).suffix(600)
                throw LoginError.failed("`\(command.joined(separator: " "))` failed: \(detail)", screenshotPath: nil)
            }
        }
    }
}

public struct LoginResult: Sendable, Equatable {
    /// Cookies and local storage of the signed-in session, for the QA browser.
    public let storageStatePath: String
    /// The check page, opened with only the saved session.
    public let screenshotPath: String
    public let finalURL: String
    /// Every origin the app contacted while signing in (its own, auth providers, CDNs). QA
    /// browsers are limited to these and the run's own ports.
    public let origins: [String]
}

public enum LoginError: Error, Equatable, LocalizedError {
    case toolsNotInstalled
    case notConfigured
    case missingSecrets([String])
    case failed(String, screenshotPath: String?)

    public var errorDescription: String? {
        switch self {
        case .toolsNotInstalled: "QA browser tools are not installed (Settings → Repositories → Local Run → Sign-in for QA)."
        case .notConfigured: "This repository has no sign-in script for QA."
        case .missingSecrets(let names): "Set these secrets in the Keychain first: \(names.joined(separator: ", "))."
        case .failed(let message, _): "Sign-in failed: \(message)"
        }
    }

    public var screenshotPath: String? {
        if case .failed(_, let path) = self { return path }
        return nil
    }
}

/// Runs a repository's login script in a headless browser and saves the session.
public enum LoginRunner {
    /// Signs in at `baseURL`. Files go to `outputDirectory`; the session itself to its `private`
    /// folder, which the local run removes when it stops.
    public static func signIn(
        config: LoginConfig,
        baseURL: String,
        secrets: [String: String],
        qaTools: QATools,
        outputDirectory: URL,
        tools: ToolEnvironment
    ) async throws -> LoginResult {
        guard qaTools.isInstalled else { throw LoginError.toolsNotInstalled }
        guard !config.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LoginError.notConfigured }
        let missing = config.secretNames.filter { (secrets[$0] ?? "").isEmpty }
        guard missing.isEmpty else { throw LoginError.missingSecrets(missing) }

        let privateDirectory = outputDirectory.appending(path: "private", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: outputDirectory)
        try FileManager.default.createDirectory(at: privateDirectory, withIntermediateDirectories: true)
        let scriptURL = outputDirectory.appending(path: "login-script.mjs")
        try "export default async ({ page, context, secret, baseURL }) => {\n\(config.script)\n};\n"
            .write(to: scriptURL, atomically: true, encoding: .utf8)
        // Next to node_modules, so `import 'playwright'` finds DevPilot's install.
        let harnessURL = qaTools.directory.appending(path: "devpilot-login.mjs")
        try harness.write(to: harnessURL, atomically: true, encoding: .utf8)

        var environment = tools.variables(base: ClaudeCodeRunner.environment())
        for name in config.secretNames {
            environment["DEVPILOT_SECRET_\(name)"] = secrets[name]
        }
        environment["DEVPILOT_BROWSER_CHANNEL"] = QATools.browserChannel
        let result = try await ProcessRunner.run(ProcessRequest(
            executable: URL(filePath: "/usr/bin/env"),
            arguments: [
                "node", harnessURL.path, scriptURL.path, baseURL, outputDirectory.path,
                config.loginPath, config.checkPath, String(config.timeoutSeconds),
            ],
            workingDirectory: qaTools.directory, environment: environment, timeout: .seconds(config.timeoutSeconds * 4 + 60)
        ))
        let output = redact(result.stdoutText + "\n" + result.stderrText, secrets: secrets)
            .replacing(/\u{1B}\[[0-9;]*m/, with: "")
        try? output.write(to: outputDirectory.appending(path: "login.log"), atomically: true, encoding: .utf8)

        let statePath = privateDirectory.appending(path: "storage-state.json").path
        guard let line = output.split(separator: "\n").last(where: { $0.hasPrefix("DEVPILOT_RESULT ") }),
              let report = try? JSONDecoder().decode(Report.self, from: Data(line.dropFirst("DEVPILOT_RESULT ".count).utf8)) else {
            try? FileManager.default.removeItem(at: privateDirectory)
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(600)
            throw LoginError.failed(detail.isEmpty ? "the browser exited (\(result.termination))." : String(detail), screenshotPath: nil)
        }
        let screenshot = report.screenshot.map { outputDirectory.appending(path: $0).path }
        guard report.ok, FileManager.default.fileExists(atPath: statePath) else {
            try? FileManager.default.removeItem(at: privateDirectory)
            let events = (report.events ?? []).isEmpty ? "" : "\nThe app reported:\n" + report.events!.map { "• \($0)" }.joined(separator: "\n")
            throw LoginError.failed((report.error ?? "no session was saved.") + events, screenshotPath: screenshot)
        }
        return LoginResult(
            storageStatePath: statePath,
            screenshotPath: outputDirectory.appending(path: "signed-in.png").path,
            finalURL: report.url ?? baseURL,
            origins: report.origins ?? []
        )
    }

    private struct Report: Decodable {
        var ok: Bool
        var error: String?
        var events: [String]?
        var origins: [String]?
        var url: String?
        var screenshot: String?
    }

    /// Replaces secret values in text shown to the user or saved to logs.
    static func redact(_ text: String, secrets: [String: String]) -> String {
        secrets.values.filter { $0.count >= 3 }.sorted { $0.count > $1.count }.reduce(text) {
            $0.replacingOccurrences(of: $1, with: "•••")
        }
    }

    static let harness = """
        // Written by DevPilot: runs a repository's login script and saves the signed-in session.
        import { chromium } from 'playwright';
        import { pathToFileURL } from 'node:url';

        const [scriptPath, baseURL, outputDir, loginPath, checkPath, timeoutSeconds] = process.argv.slice(2);
        const secret = (name) => {
          const value = process.env[`DEVPILOT_SECRET_${name}`];
          if (value === undefined) throw new Error(`Secret ${name} is not set`);
          return value;
        };
        const report = (result) => console.log('DEVPILOT_RESULT ' + JSON.stringify(result));
        // What the app complained about, for failure messages: console errors and failed requests.
        const events = [];
        const origins = new Set();
        const watch = (target) => {
          target.on('request', (request) => {
            try { const url = new URL(request.url()); if (url.protocol.startsWith('http')) origins.add(url.origin); } catch {}
          });
          target.on('console', (message) => {
            if (message.type() === 'error') events.push(`console error: ${message.text().slice(0, 300)}`);
          });
          target.on('response', (response) => {
            if (response.status() >= 400) {
              events.push(`HTTP ${response.status()} ${response.request().method()} ${response.url().split('?')[0]}`);
            }
          });
          target.on('requestfailed', (request) => {
            const reason = request.failure()?.errorText ?? '';
            // Aborted requests are mostly analytics cut off by navigation: noise.
            if (!reason.includes('ERR_ABORTED')) events.push(`request failed: ${request.method()} ${request.url().split('?')[0]} (${reason})`);
          });
        };
        const browser = await chromium.launch({ headless: true, channel: process.env.DEVPILOT_BROWSER_CHANNEL || undefined });
        let page;
        try {
          // Without a session the check page must send us to sign in; otherwise it proves nothing.
          if (loginPath.length > 1) {
            const anonymous = await browser.newContext({ baseURL });
            const anonymousPage = await anonymous.newPage();
            await anonymousPage.goto(checkPath);
            await anonymousPage.waitForURL((url) => url.pathname.startsWith(loginPath), { timeout: 15000 }).catch(() => {});
            const landed = new URL(anonymousPage.url()).pathname;
            await anonymous.close();
            if (!landed.startsWith(loginPath)) {
              throw new Error(`the check page ${checkPath} opens without signing in (it showed ${landed}), so it cannot prove a sign-in worked. Set Check page to one that redirects to ${loginPath}.`);
            }
          }
          const context = await browser.newContext({ baseURL });
          context.setDefaultTimeout(Number(timeoutSeconds) * 1000);
          page = await context.newPage();
          watch(page);
          const login = (await import(pathToFileURL(scriptPath).href)).default;
          await login({ page, context, secret, baseURL });
          const statePath = `${outputDir}/private/storage-state.json`;
          await context.storageState({ path: statePath });

          // The saved session alone, in a fresh browser context, must open the check page.
          const check = await browser.newContext({ baseURL, storageState: statePath });
          const checkPage = await check.newPage();
          watch(checkPage);
          await checkPage.goto(checkPath);
          await checkPage.waitForLoadState('networkidle', { timeout: 15000 }).catch(() => {});
          await checkPage.screenshot({ path: `${outputDir}/signed-in.png` });
          const landed = new URL(checkPage.url()).pathname;
          if (loginPath.length > 1 && landed.startsWith(loginPath)) {
            report({ ok: false, screenshot: 'signed-in.png',
                     error: `opening ${checkPath} with the saved session went to ${landed}, so the session was not kept.` });
          } else {
            report({ ok: true, url: checkPage.url(), origins: [...origins].sort() });
          }
        } catch (error) {
          let screenshot = null;
          let where = '';
          if (page) {
            try { await page.screenshot({ path: `${outputDir}/failure.png`, fullPage: true }); screenshot = 'failure.png'; } catch {}
            try { where = ` (the browser was on ${new URL(page.url()).pathname})`; } catch {}
          }
          for (const event of events) console.log(`DEVPILOT_EVENT ${event}`);
          report({ ok: false, error: String(error?.message ?? error).split('\\n')[0] + where, screenshot, events: events.slice(-6) });
        } finally {
          await browser.close();
        }

        """
}
