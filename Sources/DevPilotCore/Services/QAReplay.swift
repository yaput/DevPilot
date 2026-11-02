import Foundation

/// The outcome of replaying one reported bug.
public struct QAReplayResult: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable {
        /// Every attempt failed an expectation: the bug is real.
        case confirmed
        /// Some attempts did, some did not.
        case flaky
        /// The steps ran and every expectation held.
        case notReproduced = "not_reproduced"
        /// The steps themselves could not be run (element not found, page error).
        case couldNotReplay = "could_not_replay"
    }

    public struct Attempt: Codable, Sendable, Hashable {
        /// nil when the steps could not be run.
        public var reproduced: Bool?
        public var message: String
        /// 1-based index of the step that failed, 0 if none.
        public var failedStep: Int
        public var screenshot: String?
        public var video: String?
    }

    public var status: Status
    public var attempts: [Attempt]

    static func status(of attempts: [Attempt]) -> Status {
        let reproduced = attempts.filter { $0.reproduced == true }.count
        let clean = attempts.filter { $0.reproduced == false }.count
        if reproduced == attempts.count, reproduced > 0 { return .confirmed }
        if reproduced > 0 { return .flaky }
        return clean > 0 ? .notReproduced : .couldNotReplay
    }
}

/// Replays reproduction steps with DevPilot's own Playwright, in fresh browser contexts with the
/// QA session's sign-in. The steps are data, interpreted here; no agent-written code ever runs.
public enum QAReplayer {
    public static func replay(
        _ steps: [QAStep],
        baseURL: String,
        storageStatePath: String?,
        attempts: Int = 2,
        qaTools: QATools,
        outputDirectory: URL,
        tools: ToolEnvironment
    ) async throws -> QAReplayResult {
        guard qaTools.isInstalled else { throw LoginError.toolsNotInstalled }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let stepsURL = outputDirectory.appending(path: "steps.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(steps).write(to: stepsURL)
        let harnessURL = qaTools.directory.appending(path: "devpilot-replay.mjs")
        try harness.write(to: harnessURL, atomically: true, encoding: .utf8)

        var environment = tools.variables(base: ClaudeCodeRunner.environment())
        environment["DEVPILOT_BROWSER_CHANNEL"] = QATools.browserChannel
        let result = try await ProcessRunner.run(ProcessRequest(
            executable: URL(filePath: "/usr/bin/env"),
            arguments: ["node", harnessURL.path, baseURL, storageStatePath ?? "", stepsURL.path, outputDirectory.path, String(attempts)],
            workingDirectory: qaTools.directory, environment: environment, timeout: .seconds(120 * attempts + 60)
        ))
        let output = (result.stdoutText + "\n" + result.stderrText).replacing(/\u{1B}\[[0-9;]*m/, with: "")
        try? output.write(to: outputDirectory.appending(path: "replay.log"), atomically: true, encoding: .utf8)
        guard let line = output.split(separator: "\n").last(where: { $0.hasPrefix("DEVPILOT_REPLAY ") }),
              let reported = try? JSONDecoder().decode([QAReplayResult.Attempt].self, from: Data(line.dropFirst("DEVPILOT_REPLAY ".count).utf8)) else {
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(400)
            return QAReplayResult(status: .couldNotReplay, attempts: [
                .init(reproduced: nil, message: detail.isEmpty ? "the replay exited (\(result.termination))" : String(detail), failedStep: 0),
            ])
        }
        let attemptsWithPaths = reported.map { attempt in
            var attempt = attempt
            attempt.screenshot = attempt.screenshot.map { outputDirectory.appending(path: $0).path }
            attempt.video = attempt.video.map { outputDirectory.appending(path: $0).path }
            return attempt
        }
        return QAReplayResult(status: QAReplayResult.status(of: attemptsWithPaths), attempts: attemptsWithPaths)
    }

    static let harness = """
        // Written by DevPilot: replays QA reproduction steps (data, not code) and reports each attempt.
        import { chromium } from 'playwright';
        import { readFileSync, renameSync, rmSync } from 'node:fs';

        const [baseURL, storageState, stepsPath, outputDir, attemptCount] = process.argv.slice(2);
        const steps = JSON.parse(readFileSync(stepsPath, 'utf8'));
        const appOrigin = new URL(baseURL).origin;
        const ACTION_TIMEOUT = 10000;
        const EXPECT_TIMEOUT = 5000;
        class Expectation extends Error {}

        const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
        async function poll(check, timeout = EXPECT_TIMEOUT) {
          const deadline = Date.now() + timeout;
          for (;;) {
            try { if (await check()) return true; } catch {}
            if (Date.now() > deadline) return false;
            await sleep(200);
          }
        }

        function locate(page, step) {
          const name = step.name ? { name: step.name } : {};
          switch (step.by) {
            case 'role': return page.getByRole(step.selector, name);
            case 'label': return page.getByLabel(step.selector);
            case 'text': return page.getByText(step.selector);
            case 'placeholder': return page.getByPlaceholder(step.selector);
            case 'testid': return page.getByTestId(step.selector);
            case 'css': return page.locator(step.selector);
            default: return null;
          }
        }

        async function run(page, step, events) {
          const target = locate(page, step);
          const element = () => {
            if (!target) throw new Error(`${step.action} needs an element (by/selector)`);
            return target.first();
          };
          const describe = target ? `${step.by}=${step.selector}${step.name ? ` "${step.name}"` : ''}` : 'the page';
          switch (step.action) {
            case 'goto': {
              const url = new URL(step.value || '/', baseURL);
              if (url.origin !== appOrigin) throw new Error(`goto ${url.origin} is outside the app`);
              await page.goto(url.href);
              return;
            }
            case 'click': return element().click();
            case 'fill': return element().fill(step.value);
            case 'press': return target ? element().press(step.value) : page.keyboard.press(step.value);
            case 'select': return element().selectOption(step.value);
            case 'check': return element().check();
            case 'uncheck': return element().uncheck();
            case 'hover': return element().hover();
            case 'wait': return sleep(Math.min(Number(step.value) || 1000, 10000));
            case 'reload': return page.reload();
            case 'back': return page.goBack();
            case 'expect_visible':
              if (!(await poll(() => element().isVisible()))) throw new Expectation(`${describe} is not visible`);
              return;
            case 'expect_hidden':
              if (!(await poll(async () => !(await element().isVisible())))) throw new Expectation(`${describe} is still visible`);
              return;
            case 'expect_text': {
              const text = () => (target ? element() : page.locator('body')).innerText();
              if (!(await poll(async () => (await text()).includes(step.value)))) throw new Expectation(`${describe} does not show "${step.value}"`);
              return;
            }
            case 'expect_no_text': {
              await sleep(1000);
              const text = await (target ? element() : page.locator('body')).innerText().catch(() => '');
              if (text.includes(step.value)) throw new Expectation(`${describe} shows "${step.value}"`);
              return;
            }
            case 'expect_url':
              if (!(await poll(async () => page.url().includes(step.value)))) throw new Expectation(`the URL is ${page.url()}, not containing "${step.value}"`);
              return;
            case 'expect_value':
              if (!(await poll(async () => (await element().inputValue()) === step.value))) {
                throw new Expectation(`${describe} has value "${await element().inputValue().catch(() => '?')}", not "${step.value}"`);
              }
              return;
            case 'expect_count': {
              if (!target) throw new Error('expect_count needs an element (by/selector)');
              const expected = Number(step.value);
              if (!(await poll(async () => (await target.count()) === expected))) throw new Expectation(`${describe} matches ${await target.count()} elements, not ${expected}`);
              return;
            }
            case 'expect_no_console_errors':
              await sleep(500);
              if (events.console.length) throw new Expectation(`console errors: ${events.console.slice(0, 3).join(' | ')}`);
              return;
            case 'expect_no_server_errors':
              await sleep(500);
              if (events.server.length) throw new Expectation(`server errors: ${events.server.slice(0, 3).join(' | ')}`);
              return;
            default:
              throw new Error(`unknown action ${step.action}`);
          }
        }

        const browser = await chromium.launch({ headless: true, channel: process.env.DEVPILOT_BROWSER_CHANNEL || undefined });
        const results = [];
        try {
          for (let attempt = 1; attempt <= Number(attemptCount); attempt++) {
            const videoDir = `${outputDir}/video-tmp-${attempt}`;
            const context = await browser.newContext({
              baseURL, viewport: { width: 1280, height: 800 },
              recordVideo: { dir: videoDir, size: { width: 1280, height: 800 } },
              ...(storageState ? { storageState } : {}),
            });
            context.setDefaultTimeout(ACTION_TIMEOUT);
            const page = await context.newPage();
            const events = { console: [], server: [] };
            // Failed loads (a missing favicon) are network, not script errors; expect_no_server_errors covers the app's own.
            page.on('console', (message) => {
              if (message.type() === 'error' && !message.text().startsWith('Failed to load resource')) events.console.push(message.text().slice(0, 200));
            });
            page.on('response', (response) => {
              if (response.status() >= 500 && response.url().startsWith(appOrigin)) {
                events.server.push(`HTTP ${response.status()} ${response.request().method()} ${response.url().split('?')[0]}`);
              }
            });
            page.on('requestfailed', (request) => {
              const reason = request.failure()?.errorText ?? '';
              if (request.url().startsWith(appOrigin) && !reason.includes('ERR_ABORTED')) events.server.push(`${request.method()} ${request.url().split('?')[0]} failed (${reason})`);
            });
            const result = { reproduced: false, message: 'every expectation held', failedStep: 0 };
            for (let index = 0; index < steps.length; index++) {
              try {
                await run(page, steps[index], events);
              } catch (error) {
                const reason = String(error?.message ?? error).split('\\n')[0];
                Object.assign(result, error instanceof Expectation
                  ? { reproduced: true, message: reason, failedStep: index + 1 }
                  : { reproduced: null, message: `step ${index + 1} (${steps[index].action}) could not run: ${reason}`, failedStep: index + 1 });
                break;
              }
            }
            try { await page.screenshot({ path: `${outputDir}/attempt-${attempt}.png`, fullPage: true }); result.screenshot = `attempt-${attempt}.png`; } catch {}
            const video = page.video();
            await context.close();
            try { renameSync(await video.path(), `${outputDir}/attempt-${attempt}.webm`); result.video = `attempt-${attempt}.webm`; } catch {}
            rmSync(videoDir, { recursive: true, force: true });
            results.push(result);
          }
        } finally {
          await browser.close();
        }
        console.log('DEVPILOT_REPLAY ' + JSON.stringify(results));

        """
}
