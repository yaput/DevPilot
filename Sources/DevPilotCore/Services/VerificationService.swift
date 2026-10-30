import Foundation

/// After implementation: runs the repository's validation commands in the sandbox, lets the
/// agent fix failures a bounded number of times, then has a fresh read-only agent review the
/// result and hands the ticket to the user (`ready_for_human_review`).
public final class VerificationService: Sendable {
    private let database: AppDatabase
    private let worktrees: GitWorktreeManager
    private let runner: any AgentRunner
    private let implementation: ImplementationService
    private let validation: ValidationRunner
    private let artifacts: ArtifactStore

    public init(
        database: AppDatabase,
        worktrees: GitWorktreeManager,
        runner: any AgentRunner,
        implementation: ImplementationService,
        validationTimeout: Duration,
        artifacts: ArtifactStore
    ) {
        self.database = database
        self.worktrees = worktrees
        self.runner = runner
        self.implementation = implementation
        self.validation = ValidationRunner(timeoutPerCommand: validationTimeout)
        self.artifacts = artifacts
    }

    /// From `validating`: validate (with up to `maxFixAttempts` automatic fixes), then review.
    /// From `reviewing`: review only. From `ready_for_human_review`: validate and review again.
    /// Failing validation is never hidden: it is recorded, shown at hand-off, and given to the
    /// reviewer, who must treat it as at least a major finding.
    @discardableResult
    public func verify(
        ticketID: String,
        repository: RepositoryConfig,
        tools: ToolEnvironment,
        maxFixAttempts: Int,
        onEvent: @escaping @Sendable (RunEvent) -> Void
    ) async throws -> ReviewReport {
        if try await database.state(of: ticketID) == .readyForHumanReview {
            try await database.transition(ticketID: ticketID, to: .validating, message: "Validation and review requested")
        }
        var result: ValidationResult?
        if try await database.state(of: ticketID) == .validating {
            var attempt = 0
            while true {
                let outcome = try await validate(ticketID: ticketID, repository: repository, tools: tools, attempt: attempt,
                                                 isFinal: { $0.passed || attempt >= maxFixAttempts }, onEvent: onEvent)
                result = outcome
                if outcome.passed || attempt >= maxFixAttempts { break }
                attempt += 1
                onEvent(.progress("Validation failed. Automatic fix attempt \(attempt) of \(maxFixAttempts)"))
                _ = try await implementation.implement(
                    ticketID: ticketID, repository: repository, tools: tools,
                    fixInstructions: Self.fixInstructions(for: outcome), onEvent: onEvent
                )
            }
        }
        let latest: ValidationResult
        if let result {
            latest = result
        } else {
            latest = try await latestValidation(ticketID: ticketID)
        }
        return try await review(ticketID: ticketID, validation: latest, onEvent: onEvent)
    }

    /// Instructions for the implementer when validation commands fail.
    public static func fixInstructions(for result: ValidationResult) -> String {
        "These validation commands failed after your changes. Make them pass without weakening, skipping or deleting tests:\n"
            + result.failed.map { failed in
                let status = failed.timedOut ? "timed out" : "exit \(failed.exitCode.map(String.init) ?? "signal")"
                return "- `\(failed.command)` (\(status)). Last output:\n" + failed.outputTail
                    .split(separator: "\n", omittingEmptySubsequences: false).suffix(40).map { "    " + $0 }.joined(separator: "\n")
            }.joined(separator: "\n")
    }

    // MARK: - Steps

    private func validate(
        ticketID: String,
        repository: RepositoryConfig,
        tools: ToolEnvironment,
        attempt: Int,
        isFinal: (ValidationResult) -> Bool,
        onEvent: @escaping @Sendable (RunEvent) -> Void
    ) async throws -> ValidationResult {
        let workspace = try await requireWorkspace(ticketID)
        let logDirectory = artifacts.runLogURL(ticketID: ticketID, kind: .validation, at: Date()).deletingPathExtension()
        let runID = try await database.beginVerificationRun(.validation, ticketID: ticketID, in: .validating, logPath: logDirectory.path)
        onEvent(.started)
        do {
            let result = try await validation.run(
                commands: repository.validationCommands.filter(\.isEnabled).map(\.command),
                worktree: workspace.worktreePath,
                commonGitDirectory: try await worktrees.commonGitDirectory(of: workspace.worktreePath),
                tools: tools,
                logDirectory: logDirectory,
                fixAttempt: attempt,
                onProgress: { onEvent(.progress($0)) },
                onLaunch: { [database] group in Task { try? await database.recordProcessGroup(runID: runID, processGroup: group) } }
            )
            try await database.completeValidation(runID: runID, ticketID: ticketID, result: result, thenReview: isFinal(result))
            return result
        } catch {
            await record(error, runID: runID, ticketID: ticketID)
            throw error
        }
    }

    private func review(ticketID: String, validation: ValidationResult, onEvent: @escaping @Sendable (RunEvent) -> Void) async throws -> ReviewReport {
        guard let ticket = try await database.ticket(id: ticketID) else { throw WorkflowError.unknownTicket(ticketID) }
        guard let plan = try await database.latestDecisionDocument(ticketID: ticketID) else {
            throw WorkflowError.implementationBlocked(.missingPlan)
        }
        let workspace = try await requireWorkspace(ticketID)
        let logURL = artifacts.runLogURL(ticketID: ticketID, kind: .review, at: Date())
        let runID = try await database.beginVerificationRun(.review, ticketID: ticketID, in: .reviewing, logPath: logURL.path)
        onEvent(.started)
        do {
            onEvent(.progress("Independent review started"))
            let request = ReviewRequest(
                ticket: ticket, workspace: workspace, plan: plan,
                implementation: try await database.runs(ticketID: ticketID).last { $0.implementation != nil }?.implementation?.report,
                validation: validation,
                diff: try await worktrees.unifiedDiff(in: workspace.worktreePath, against: workspace.baseCommit),
                commonGitDirectory: try await worktrees.commonGitDirectory(of: workspace.worktreePath),
                logURL: logURL,
                onLaunch: { [database] group in Task { try? await database.recordProcessGroup(runID: runID, processGroup: group) } }
            )
            let (report, stats) = try await runner.review(request) { onEvent(.progress($0)) }
            let markdown = ReviewDocumentRenderer.render(report, validation: validation, ticket: ticket, workspace: workspace, planVersion: plan.version)
            try? markdown.write(to: logURL.deletingPathExtension().appendingPathExtension("md"), atomically: true, encoding: .utf8)
            try await database.completeReview(runID: runID, ticketID: ticketID, report: report, stats: stats)
            return report
        } catch {
            await record(error, runID: runID, ticketID: ticketID)
            throw error
        }
    }

    private func latestValidation(ticketID: String) async throws -> ValidationResult {
        try await database.runs(ticketID: ticketID).last { $0.validation != nil }?.validation
            ?? ValidationResult(commands: [], fixAttempt: 0)
    }

    private func requireWorkspace(_ ticketID: String) async throws -> TicketWorkspace {
        guard let workspace = try await database.workspace(ticketID: ticketID),
              FileManager.default.fileExists(atPath: workspace.worktreePath) else {
            throw ImplementationError.worktreeMissing("the ticket's worktree")
        }
        return workspace
    }

    /// The ticket stays where it rests (`validating` / `reviewing`) so the step can be re-run.
    private func record(_ error: Error, runID: Int64, ticketID: String) async {
        let outcome: AgentRun.Outcome = switch error {
        case is CancellationError: .cancelled
        case AgentError.timedOut: .timedOut
        default: .failed
        }
        let message = outcome == .cancelled ? "Stopped by user" : error.localizedDescription
        await Task {
            try? await database.finishRun(runID: runID, ticketID: ticketID, outcome: outcome, message: message)
        }.value
    }
}
