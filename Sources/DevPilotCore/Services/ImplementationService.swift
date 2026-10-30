import Foundation

public enum ImplementationError: Error, Equatable, LocalizedError {
    case worktreeMissing(String)
    case setupFailed(command: String, detail: String)
    case commitsCreated(before: String, after: String)
    case blocked(String)

    public var errorDescription: String? {
        switch self {
        case .worktreeMissing(let path):
            "The ticket's worktree is missing (\(path)). Restart the ticket to create a new one."
        case .setupFailed(let command, let detail):
            "Setup command `\(command)` failed: \(detail)"
        case .commitsCreated(let before, let after):
            "HEAD moved from \(before.prefix(8)) to \(after.prefix(8)) during the run; DevPilot never commits. The changes are left in place for you to inspect."
        case .blocked(let summary):
            "Claude stopped without changing anything: \(summary)"
        }
    }
}

/// Implements an approved plan in the ticket's worktree and records what changed.
public final class ImplementationService: Sendable {
    static let setupTimeout: Duration = .seconds(20 * 60)

    private let database: AppDatabase
    private let worktrees: GitWorktreeManager
    private let runner: any AgentRunner
    private let artifacts: ArtifactStore

    public init(database: AppDatabase, worktrees: GitWorktreeManager, runner: any AgentRunner, artifacts: ArtifactStore) {
        self.database = database
        self.worktrees = worktrees
        self.runner = runner
        self.artifacts = artifacts
    }

    /// Starts from `approved`. Runs the repository's enabled setup commands, then the agent,
    /// then verifies no commits were made and moves the ticket to `validating`.
    public func implement(
        ticketID: String,
        repository: RepositoryConfig,
        tools: ToolEnvironment,
        onEvent: @escaping @Sendable (RunEvent) -> Void
    ) async throws -> ImplementationResult {
        guard let ticket = try await database.ticket(id: ticketID) else { throw WorkflowError.unknownTicket(ticketID) }
        guard let workspace = try await database.workspace(ticketID: ticketID) else {
            throw ImplementationError.worktreeMissing("no worktree recorded")
        }
        guard FileManager.default.fileExists(atPath: workspace.worktreePath) else {
            throw ImplementationError.worktreeMissing(workspace.worktreePath)
        }
        let logURL = artifacts.runLogURL(ticketID: ticketID, kind: .implementation, at: Date())
        let (runID, plan) = try await database.beginImplementation(ticketID: ticketID, logPath: logURL.path)
        onEvent(.started)

        do {
            let headBefore = try await worktrees.head(of: workspace.worktreePath)
            let setupLog = logURL.deletingPathExtension().appendingPathExtension("setup.log")
            for rule in repository.setupCommands where rule.isEnabled {
                onEvent(.progress("Setup: \(rule.command)"))
                try await runSetup(rule.command, in: workspace.worktreePath, tools: tools, log: setupLog)
            }

            let request = ImplementationRequest(
                ticket: ticket,
                workspace: workspace,
                plan: plan,
                allowedCommands: repository.agentCommands.filter(\.isEnabled).map(\.command),
                commonGitDirectory: try await worktrees.commonGitDirectory(of: workspace.worktreePath),
                tools: tools,
                logURL: logURL,
                onLaunch: { [database] group in
                    Task { try? await database.recordProcessGroup(runID: runID, processGroup: group) }
                }
            )
            let (report, stats) = try await runner.implement(request) { onEvent(.progress($0)) }

            // The sandbox makes git metadata read-only; this catches anything that slipped through.
            let headAfter = try await worktrees.head(of: workspace.worktreePath)
            guard headAfter == headBefore else {
                throw ImplementationError.commitsCreated(before: headBefore, after: headAfter)
            }
            let result = ImplementationResult(
                report: report,
                changedFiles: try await worktrees.changedFiles(in: workspace.worktreePath),
                planVersion: plan.version
            )
            // Nothing to validate: fail with the agent's explanation, keeping its report.
            if report.outcome == .blocked && result.changedFiles.isEmpty {
                let error = ImplementationError.blocked(report.summary)
                await Task {
                    try? await database.finishRun(
                        runID: runID, ticketID: ticketID, outcome: .failed, message: error.localizedDescription, result: result
                    )
                }.value
                throw error
            }
            try await database.completeImplementation(runID: runID, ticketID: ticketID, result: result, stats: stats)
            return result
        } catch {
            if case ImplementationError.blocked = error {
                throw error  // Already recorded, with the agent's report.
            }
            let outcome: AgentRun.Outcome = switch error {
            case is CancellationError: .cancelled
            case AgentError.timedOut: .timedOut
            default: .failed
            }
            let message = outcome == .cancelled ? "Stopped by user" : error.localizedDescription
            // Recorded from a fresh task: the current one may be cancelled.
            await Task {
                try? await database.finishRun(runID: runID, ticketID: ticketID, outcome: outcome, message: message)
            }.value
            throw error
        }
    }

    /// Setup commands are written by the user in Settings, so they run through the shell, with
    /// network access, outside the agent sandbox, in the worktree.
    private func runSetup(_ command: String, in worktree: String, tools: ToolEnvironment, log: URL) async throws {
        let result = try await ProcessRunner.run(ProcessRequest(
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", command],
            workingDirectory: URL(filePath: worktree, directoryHint: .isDirectory),
            environment: tools.variables(base: ClaudeCodeRunner.environment()),
            timeout: Self.setupTimeout
        ))
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        let entry = "$ \(command)\n\(result.stdoutText)\(result.stderrText)\n[\(result.timedOut ? "timed out" : "\(result.termination)")]\n\n"
        if let handle = try? FileHandle(forWritingTo: log) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(entry.utf8))
            try? handle.close()
        } else {
            try? entry.write(to: log, atomically: true, encoding: .utf8)
        }
        guard result.succeeded else {
            let tail = (result.stderrText.isEmpty ? result.stdoutText : result.stderrText)
                .trimmingCharacters(in: .whitespacesAndNewlines).suffix(400)
            throw ImplementationError.setupFailed(
                command: command,
                detail: result.timedOut ? "timed out after \(Self.setupTimeout.components.seconds / 60) minutes" : "\(result.termination). \(tail)"
            )
        }
    }
}
