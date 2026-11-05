import Foundation

/// The claude.ai plan's usage, as `/usage` in Claude Code shows it: the 5-hour session window and
/// the weekly window. Claude Code streams it as `rate_limit_event`s in every run, so DevPilot's
/// own runs keep it current; `ClaudeCLI.fetchUsage` asks for it when nothing is running.
public struct ClaudeUsage: Codable, Sendable, Equatable {
    public struct Window: Codable, Sendable, Equatable {
        /// 0...1 of the window's limit.
        public var utilization: Double
        public var resetsAt: Date
        /// "allowed", "allowed_warning" (close to the limit) or "rejected" (limit reached).
        public var status: String

        public init(utilization: Double, resetsAt: Date, status: String) {
            self.utilization = utilization
            self.resetsAt = resetsAt
            self.status = status
        }
    }

    /// The 5-hour window.
    public var session: Window?
    /// The 7-day window.
    public var weekly: Window?
    /// Past the plan's limits and paying for extra usage.
    public var isUsingOverage: Bool
    public var updatedAt: Date

    public init(session: Window?, weekly: Window?, isUsingOverage: Bool, updatedAt: Date) {
        self.session = session
        self.weekly = weekly
        self.isUsingOverage = isUsingOverage
        self.updatedAt = updatedAt
    }

    /// From one stream-json event; nil for any other event.
    public init?(event: JSONValue, at date: Date = Date()) {
        guard event["type"]?.string == "rate_limit_event", let info = event["rate_limit_info"] else { return nil }
        func window(_ key: String) -> Window? {
            guard let value = info["unifiedWindows"]?[key], let utilization = value["utilization"]?.number,
                  let resetsAt = value["resetsAt"]?.number else { return nil }
            return Window(
                utilization: utilization, resetsAt: Date(timeIntervalSince1970: resetsAt), status: value["status"]?.string ?? "allowed"
            )
        }
        session = window("five_hour")
        weekly = window("seven_day")
        guard session != nil || weekly != nil else { return nil }
        isUsingOverage = info["isUsingOverage"] == .bool(true)
        updatedAt = date
    }

    /// Newer windows replace older ones; a window the newer reading lacks is kept.
    public func updated(with newer: ClaudeUsage) -> ClaudeUsage {
        ClaudeUsage(
            session: newer.session ?? session, weekly: newer.weekly ?? weekly,
            isUsingOverage: newer.isUsingOverage, updatedAt: newer.updatedAt
        )
    }

    /// The window as of `now`: once its reset time has passed it starts again from zero.
    public static func current(_ window: Window?, now: Date = Date()) -> Window? {
        guard let window else { return nil }
        return window.resetsAt <= now ? nil : window
    }
}

/// The last reading, kept so it shows right after launch.
public struct ClaudeUsageStore: Sendable {
    public let url: URL

    public init(directory: URL) {
        url = directory.appending(path: "claude-usage.json")
    }

    public func read() -> ClaudeUsage? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(ClaudeUsage.self, from: $0) }
    }

    public func write(_ usage: ClaudeUsage) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(usage).write(to: url, options: .atomic)
    }
}

public enum ClaudeUsageError: Error, LocalizedError {
    case noReading(String)

    public var errorDescription: String? {
        switch self {
        case .noReading(let detail): "Claude Code did not report usage. \(detail)"
        }
    }
}

extension ClaudeCLI {
    /// One tiny request to the smallest model (no tools, no settings, no saved session), read for
    /// the usage Claude Code reports with it. Costs a few thousand Haiku tokens.
    public static func fetchUsage(executable: URL) async throws -> ClaudeUsage {
        let result = try await ProcessRunner.run(ProcessRequest(
            executable: executable,
            arguments: [
                "-p", "--model", "haiku", "--output-format", "stream-json", "--verbose",
                "--setting-sources", "", "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
                "--no-session-persistence", "--tools", "",
            ],
            workingDirectory: FileManager.default.temporaryDirectory,
            environment: ClaudeCodeRunner.environment(),
            stdin: Data("Reply with OK.".utf8),
            timeout: .seconds(60)
        ))
        let usage = result.stdoutText.split(whereSeparator: \.isNewline).reduce(nil as ClaudeUsage?) { found, line in
            guard let event = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
                  let reading = ClaudeUsage(event: event) else { return found }
            return found.map { $0.updated(with: reading) } ?? reading
        }
        guard let usage else {
            let detail = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ClaudeUsageError.noReading(detail.isEmpty ? "Is Claude Code logged in with a claude.ai account?" : String(detail.suffix(300)))
        }
        return usage
    }
}
