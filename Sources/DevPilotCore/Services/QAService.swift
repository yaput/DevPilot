import Foundation

public struct QASessionResult: Codable, Sendable, Hashable {
    public let directory: String
    public let report: QAReport
    /// One per finding, in the same order.
    public let replays: [QAReplayResult]
    public let startedAt: Date
    public let finishedAt: Date
    public let reportPath: String

    public var confirmedCount: Int { replays.filter { $0.status == .confirmed }.count }
}

/// A QA session against a ticket's local run: an agent explores the app in DevPilot's
/// Playwright browser (already signed in), then DevPilot replays every reported bug itself.
/// Everything lands in `artifacts/<ticket>/qa/<time>/`.
public final class QAService: Sendable {
    private let database: AppDatabase
    private let worktrees: GitWorktreeManager
    private let runner: any QARunner
    private let artifacts: ArtifactStore

    public init(database: AppDatabase, worktrees: GitWorktreeManager, runner: any QARunner, artifacts: ArtifactStore) {
        self.database = database
        self.worktrees = worktrees
        self.runner = runner
        self.artifacts = artifacts
    }

    public func run(
        ticketID: String,
        localRun: LocalRunStatus,
        signIn: LoginResult?,
        qaTools: QATools,
        tools: ToolEnvironment,
        timeLimitMinutes: Int,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> QASessionResult {
        guard qaTools.isInstalled else { throw LoginError.toolsNotInstalled }
        guard let appURL = localRun.appURL else { throw LocalRunError.notConfigured }
        guard let ticket = try await database.ticket(id: ticketID) else { throw WorkflowError.unknownTicket(ticketID) }
        guard let workspace = try await database.workspace(ticketID: ticketID) else {
            throw ImplementationError.worktreeMissing("the ticket's worktree")
        }
        let startedAt = Date()
        let session = Self.sessionDirectory(artifacts.directory(for: ticketID), startedAt: startedAt)
        try FileManager.default.createDirectory(at: session.appending(path: "browser"), withIntermediateDirectories: true)

        let mcpConfig = try Self.writeMCPConfig(
            session: session, qaTools: qaTools, tools: tools, storageStatePath: signIn?.storageStatePath,
            allowedOrigins: signIn.map { Self.allowedOrigins(signIn: $0, localRun: localRun) }
        )
        let diff = (try? await worktrees.unifiedDiff(in: workspace.worktreePath, against: workspace.baseCommit)) ?? ""
        let request = QARequest(
            ticket: ticket, workspace: workspace, plan: try await database.latestDecisionDocument(ticketID: ticketID),
            changedFiles: Self.changedFiles(inDiff: diff), appURL: appURL, signedIn: signIn != nil,
            serviceLogs: localRun.services.map { ($0.name, $0.logPath) }, logDirectory: localRun.logDirectory,
            excludedDirectory: localRun.qaLoginDirectory.path, mcpConfigPath: mcpConfig.path,
            sessionDirectory: session.path, timeLimitMinutes: timeLimitMinutes,
            logURL: session.appending(path: "agent.jsonl")
        )
        onProgress("QA agent started (up to \(timeLimitMinutes) minutes)")
        let (report, _) = try await runner.exploreQA(request, onProgress: onProgress)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: session.appending(path: "report.json"))

        var replays: [QAReplayResult] = []
        for (index, finding) in report.findings.enumerated() {
            onProgress("Replaying bug \(index + 1) of \(report.findings.count): \(finding.title)")
            guard !finding.reproduction.isEmpty else {
                replays.append(QAReplayResult(status: .couldNotReplay, attempts: [
                    .init(reproduced: nil, message: "The agent gave no reproduction steps.", failedStep: 0),
                ]))
                continue
            }
            replays.append(try await QAReplayer.replay(
                QAStep.tidy(finding.reproduction, pageURL: finding.pageURL), baseURL: appURL, storageStatePath: signIn?.storageStatePath, qaTools: qaTools,
                outputDirectory: session.appending(path: "replays/bug-\(index + 1)", directoryHint: .isDirectory), tools: tools
            ))
        }

        let reportURL = session.appending(path: "qa-report.md")
        let result = QASessionResult(
            directory: session.path, report: report, replays: replays, startedAt: startedAt, finishedAt: Date(), reportPath: reportURL.path
        )
        try QAReportRenderer.render(result, ticket: ticket, workspace: workspace, appURL: appURL)
            .write(to: reportURL, atomically: true, encoding: .utf8)
        try encoder.encode(result).write(to: session.appending(path: "session.json"))
        return result
    }

    /// Past sessions of a ticket, newest first.
    public func sessions(ticketID: String) -> [QASessionResult] {
        let root = artifacts.directory(for: ticketID).appending(path: "qa", directoryHint: .isDirectory)
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        return folders.compactMap { folder in
            (try? Data(contentsOf: folder.appending(path: "session.json"))).flatMap { try? decoder.decode(QASessionResult.self, from: $0) }
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    static func sessionDirectory(_ ticketDirectory: URL, startedAt: Date) -> URL {
        let stamp = startedAt.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).dateTimeSeparator(.standard))
            .replacingOccurrences(of: ":", with: "")
        return ticketDirectory.appending(path: "qa/\(stamp)", directoryHint: .isDirectory)
    }

    /// What the app used while signing in, plus the run's own ports on both loopback names.
    static func allowedOrigins(signIn: LoginResult, localRun: LocalRunStatus) -> [String] {
        let local = localRun.services.compactMap(\.port).flatMap { ["http://localhost:\($0)", "http://127.0.0.1:\($0)"] }
        return Array(Set(signIn.origins + local)).sorted()
    }

    static func changedFiles(inDiff diff: String) -> [String] {
        var files: [String] = []
        for match in diff.matches(of: /(?m)^diff --git a\/.+? b\/(.+)$/) where !files.contains(String(match.1)) {
            files.append(String(match.1))
        }
        return files
    }

    /// The Playwright MCP server: headless Chrome, a fresh in-memory profile with the saved
    /// session, a recorded video, and output files kept in the session folder.
    static func writeMCPConfig(
        session: URL, qaTools: QATools, tools: ToolEnvironment, storageStatePath: String?, allowedOrigins: [String]?
    ) throws -> URL {
        var contextOptions: [String: Any] = [
            "viewport": ["width": 1280, "height": 800],
            "recordVideo": ["dir": session.appending(path: "video").path, "size": ["width": 1280, "height": 800]],
        ]
        if let storageStatePath { contextOptions["storageState"] = storageStatePath }
        var launchOptions: [String: Any] = ["headless": true]
        if let channel = QATools.browserChannel { launchOptions["channel"] = channel }
        var playwright: [String: Any] = [
            "browser": ["browserName": "chromium", "isolated": true, "launchOptions": launchOptions, "contextOptions": contextOptions],
            "capabilities": ["core", "core-navigation", "core-tabs", "core-input", "network", "storage", "testing"],
            "outputDir": session.appending(path: "browser").path,
            "console": ["level": "warning"],
            "webmcp": false,
        ]
        if let allowedOrigins { playwright["network"] = ["allowedOrigins": allowedOrigins] }
        let playwrightURL = session.appending(path: "playwright-mcp.json")
        try JSONSerialization.data(withJSONObject: playwright, options: [.prettyPrinted, .sortedKeys]).write(to: playwrightURL)

        // Started from the session folder, so any file the browser writes lands there.
        let command = #"cd "$1" && exec node "$2" --config "$3""#
        let server: [String: Any] = [
            "type": "stdio",
            "command": "/bin/sh",
            "args": ["-c", command, "devpilot-qa-mcp", session.path,
                     qaTools.directory.appending(path: "node_modules/@playwright/mcp/cli.js").path, playwrightURL.path],
            "env": ["PATH": tools.variables(base: [:])["PATH"] ?? ToolEnvironment.systemPath],
        ]
        let mcpURL = session.appending(path: "mcp-config.json")
        try JSONSerialization.data(withJSONObject: ["mcpServers": ["playwright": server]], options: [.prettyPrinted, .sortedKeys])
            .write(to: mcpURL)
        return mcpURL
    }
}

public enum QAReportRenderer {
    public static func render(_ result: QASessionResult, ticket: Ticket, workspace: TicketWorkspace, appURL: String) -> String {
        let session = URL(filePath: result.directory)
        func relative(_ path: String) -> String {
            path.hasPrefix(session.path + "/") ? String(path.dropFirst(session.path.count + 1)) : path
        }
        let minutes = max(1, Int(result.finishedAt.timeIntervalSince(result.startedAt) / 60))
        let counts = Dictionary(grouping: result.replays, by: \.status).mapValues(\.count)
        var lines = [
            "# QA: \(ticket.title)",
            "",
            "- Ticket: [\(ticket.externalID)](\(ticket.url.absoluteString))",
            "- Branch: `\(workspace.branch)`, app at \(appURL)",
            "- \(result.startedAt.formatted(date: .abbreviated, time: .shortened)), about \(minutes) min",
            "- Bugs: \(result.report.findings.count) reported; \(counts[.confirmed] ?? 0) reproduced by replay, "
                + "\(counts[.flaky] ?? 0) flaky, \(counts[.notReproduced] ?? 0) not reproduced, \(counts[.couldNotReplay] ?? 0) could not be replayed",
            "", "## Summary", "", result.report.summary, "", "## Bugs", "",
        ]
        if result.report.findings.isEmpty { lines.append("_None found._") }
        let ordered = zip(result.report.findings, result.replays).enumerated().sorted { $0.element.0.severity < $1.element.0.severity }
        for (index, (finding, replay)) in ordered {
            lines += [
                "### \(index + 1). [\(label(replay.status))] \(finding.severity.rawValue.uppercased()): \(finding.title)",
                "",
                "- Category: \(finding.category); page: \(finding.pageURL)",
                "- Expected: \(finding.expected)",
                "- Actual: \(finding.actual)",
            ]
            if !finding.steps.isEmpty {
                lines += ["- Steps:"] + finding.steps.enumerated().map { "  \($0.offset + 1). \($0.element)" }
            }
            if !finding.evidence.isEmpty { lines += ["- Evidence:", "  ```", finding.evidence, "  ```"] }
            lines.append("- Replay (DevPilot, \(replay.attempts.count) fresh browsers):")
            for (number, attempt) in replay.attempts.enumerated() {
                let media = [attempt.video.map { "[video](\(relative($0)))" }, attempt.screenshot.map { "[screenshot](\(relative($0)))" }]
                    .compactMap { $0 }.joined(separator: ", ")
                lines.append("  \(number + 1). \(attempt.message)\(media.isEmpty ? "" : " (\(media))")")
            }
            lines += ["- Reproduction steps:"] + finding.reproduction.enumerated().map { "  \($0.offset + 1). `\($0.element.summary)`" }
            lines.append("")
        }
        lines += ["## Coverage", "", "| Area | Result | Note |", "| --- | --- | --- |"]
        lines += result.report.coverage.map { "| \($0.area) | \($0.result.rawValue) | \($0.note.replacingOccurrences(of: "|", with: "/")) |" }
        lines += ["", "## Notes", ""]
        lines += result.report.notes.isEmpty ? ["_None._"] : result.report.notes.map { "- \($0)" }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func label(_ status: QAReplayResult.Status) -> String {
        switch status {
        case .confirmed: "REPRODUCED"
        case .flaky: "FLAKY"
        case .notReproduced: "NOT REPRODUCED"
        case .couldNotReplay: "NOT REPLAYED"
        }
    }
}
