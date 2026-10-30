import Foundation
import Synchronization

/// Drives the Claude Code CLI in headless mode.
///
/// Read-only enforcement does not rely on the prompt: only Read/Grep/Glob are available
/// (`--tools`), anything else is denied without asking (`--permission-mode dontAsk`), repository
/// settings, hooks and MCP servers are ignored (`--setting-sources user`, `--strict-mcp-config`),
/// and the process gets a minimal environment without API keys or SSH agent.
public struct ClaudeCodeRunner: AgentRunner {
    static let readOnlyTools = ["Read", "Grep", "Glob"]

    private let executable: URL
    private let model: String?
    private let timeout: Duration

    public init(executable: URL, model: String?, timeout: Duration) {
        self.executable = executable
        self.model = model?.trimmingCharacters(in: .whitespaces).isEmpty == false ? model : nil
        self.timeout = timeout
    }

    public func investigate(
        _ request: InvestigationRequest,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> (Investigation, AgentRunStats) {
        let prompt = InvestigationPrompt.render(request)
        let log = try TranscriptLog(url: request.logURL, prompt: prompt)
        let finalEvent = Mutex<JSONValue?>(nil)
        let worktree = request.workspace.worktreePath

        let result = try await ProcessRunner.run(
            ProcessRequest(
                executable: executable,
                arguments: investigationArguments(),
                workingDirectory: URL(filePath: worktree, directoryHint: .isDirectory),
                environment: Self.environment(),
                stdin: Data(prompt.utf8),
                timeout: timeout
            )
        ) { line in
            log.append(line)
            guard let event = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else { return }
            if event["type"]?.string == "result" {
                finalEvent.withLock { $0 = event }
            }
            for message in Self.progressMessages(from: event, worktree: worktree) {
                onProgress(message)
            }
        }
        log.close(stderr: result.stderrText)

        if result.timedOut {
            throw AgentError.timedOut(minutes: Int(timeout.components.seconds / 60))
        }
        return try Self.parseResult(finalEvent.withLock { $0 }, process: result)
    }

    func investigationArguments() -> [String] {
        var arguments = [
            "-p",
            "--output-format", "stream-json", "--verbose",
            "--json-schema", InvestigationPrompt.schema,
            "--tools", Self.readOnlyTools.joined(separator: ","),
            "--allowedTools", Self.readOnlyTools.joined(separator: ","),
            "--permission-mode", "dontAsk",
            "--setting-sources", "user",
            "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
            "--no-session-persistence",
            "--append-system-prompt", InvestigationPrompt.policy,
        ]
        if let model {
            arguments += ["--model", model]
        }
        return arguments
    }

    /// Only what Claude Code needs to find its login. `ANTHROPIC_API_KEY` is deliberately
    /// absent so the stored claude.ai login is used, as are SSH and cloud credentials.
    static func environment() -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8",
            "TERM": "dumb",
            "DISABLE_AUTOUPDATER": "1",
        ]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR"] {
            environment[key] = inherited[key]
        }
        environment["HOME"] = environment["HOME"] ?? NSHomeDirectory()
        return environment
    }

    static func parseResult(_ event: JSONValue?, process: ProcessResult) throws -> (Investigation, AgentRunStats) {
        guard let event else {
            let detail = process.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = detail.isEmpty ? "Claude Code exited (\(process.termination)) without a result." : String(detail.suffix(500))
            throw looksLikeLoginProblem(message) ? AgentError.notLoggedIn(message) : AgentError.failed(message)
        }
        let resultText = event["result"]?.string ?? ""
        guard event["is_error"] != .bool(true), event["subtype"]?.string == "success" else {
            let message = resultText.isEmpty ? (event["subtype"]?.string ?? "unknown error") : String(resultText.prefix(500))
            throw looksLikeLoginProblem(message) ? AgentError.notLoggedIn(message) : AgentError.failed(message)
        }
        guard let structured = event["structured_output"], case .object = structured else {
            throw AgentError.invalidOutput("No structured output in the result.")
        }
        let investigation: Investigation
        do {
            investigation = try JSONDecoder().decode(Investigation.self, from: JSONEncoder().encode(structured))
        } catch {
            throw AgentError.invalidOutput("\(error)")
        }
        let stats = AgentRunStats(
            numTurns: event["num_turns"]?.number.map { Int($0) },
            costUSD: event["total_cost_usd"]?.number
        )
        return (investigation, stats)
    }

    private static func looksLikeLoginProblem(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("/login") || lowered.contains("not logged in") || lowered.contains("invalid api key")
    }

    /// Short, human-readable activity lines from stream-json events.
    static func progressMessages(from event: JSONValue, worktree: String) -> [String] {
        switch event["type"]?.string {
        case "system" where event["subtype"]?.string == "init":
            let model = event["model"]?.string ?? "default model"
            return ["Claude Code started (\(model))"]
        case "assistant":
            return (event["message"]?["content"]?.array ?? []).compactMap { block in
                guard block["type"]?.string == "tool_use" else { return nil }
                let input = block["input"]
                func relative(_ path: String?) -> String {
                    guard let path else { return "?" }
                    return path.hasPrefix(worktree + "/") ? String(path.dropFirst(worktree.count + 1)) : path
                }
                switch block["name"]?.string {
                case "Read": return "Reading \(relative(input?["file_path"]?.string))"
                case "Grep":
                    let scope = input?["path"]?.string.map { " in \(relative($0))" } ?? ""
                    return "Searching for “\(input?["pattern"]?.string ?? "")”\(scope)"
                case "Glob": return "Listing \(input?["pattern"]?.string ?? "files")"
                case "StructuredOutput": return "Writing the decision record"
                case let name?: return "Using \(name)"
                case nil: return nil
                }
            }
        default:
            return []
        }
    }
}

/// Writes the prompt and the raw stream-json transcript next to each other, outside the worktree.
final class TranscriptLog: Sendable {
    private let handle: Mutex<FileHandle?>
    private let url: URL

    init(url: URL, prompt: String) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try prompt.write(to: url.deletingPathExtension().appendingPathExtension("prompt.md"), atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = Mutex(try FileHandle(forWritingTo: url))
    }

    func append(_ line: String) {
        handle.withLock { try? $0?.write(contentsOf: Data((line + "\n").utf8)) }
    }

    func close(stderr: String) {
        handle.withLock {
            try? $0?.close()
            $0 = nil
        }
        if !stderr.isEmpty {
            try? stderr.write(to: url.deletingPathExtension().appendingPathExtension("stderr.txt"), atomically: true, encoding: .utf8)
        }
    }
}

/// Finds the `claude` executable (GUI apps do not inherit the shell PATH) and checks its login.
public enum ClaudeCLI {
    public struct Status: Sendable, Equatable {
        public let version: String
        public let loggedIn: Bool
        public let authMethod: String?
        public let subscription: String?

        public var summary: String {
            guard loggedIn else { return "Claude Code \(version) — not logged in" }
            let plan = subscription.map { " (\($0))" } ?? ""
            return "Claude Code \(version) — logged in via \(authMethod ?? "unknown")\(plan)"
        }
    }

    public static func candidates(home: String = NSHomeDirectory()) -> [String] {
        [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.bun/bin/claude",
        ]
    }

    /// The configured path if it is executable, otherwise the first executable candidate.
    public static func resolve(configuredPath: String, home: String = NSHomeDirectory()) -> URL? {
        let configured = (configuredPath.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        if !configured.isEmpty {
            return FileManager.default.isExecutableFile(atPath: configured) ? URL(filePath: configured) : nil
        }
        return candidates(home: home).first(where: FileManager.default.isExecutableFile(atPath:)).map { URL(filePath: $0) }
    }

    /// Runs `claude --version` and `claude auth status` with the same environment agent runs use.
    public static func status(executable: URL) async throws -> Status {
        func run(_ arguments: [String]) async throws -> String {
            let result = try await ProcessRunner.run(ProcessRequest(
                executable: executable, arguments: arguments,
                workingDirectory: URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory),
                environment: ClaudeCodeRunner.environment(), timeout: .seconds(30)
            ))
            return result.stdoutText
        }
        let version = try await run(["--version"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let authOutput = try await run(["auth", "status"])
        let json = authOutput.firstIndex(of: "{").flatMap {
            try? JSONDecoder().decode(JSONValue.self, from: Data(authOutput[$0...].utf8))
        }
        return Status(
            version: version.components(separatedBy: " ").first ?? version,
            loggedIn: json?["loggedIn"] == .bool(true),
            authMethod: json?["authMethod"]?.string,
            subscription: json?["subscriptionType"]?.string
        )
    }
}
