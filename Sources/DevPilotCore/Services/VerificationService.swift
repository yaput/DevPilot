import Foundation

/// A QA session for one ticket inside the pipeline: run the app locally, sign in, explore,
/// replay, stop. The app supplies it, because it owns the single local environment and the
/// Keychain. Throws when QA could not run at all (no tools, app failed to start, sign-in failed).
public protocol PipelineQA: Sendable {
    func runQA(
        ticketID: String,
        repository: RepositoryConfig,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> QASessionResult
}

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
    private let qa: (any PipelineQA)?

    public init(
        database: AppDatabase,
        worktrees: GitWorktreeManager,
        runner: any AgentRunner,
        implementation: ImplementationService,
        validationTimeout: Duration,
        artifacts: ArtifactStore,
        buildGate: BuildGate? = nil,
        qa: (any PipelineQA)? = nil
    ) {
        self.qa = qa
        self.database = database
        self.worktrees = worktrees
        self.runner = runner
        self.implementation = implementation
        self.validation = ValidationRunner(timeoutPerCommand: validationTimeout, buildGate: buildGate)
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
        var qaResult: QASessionResult?
        if try await database.state(of: ticketID) == .validating {
            // QA follows passing tests when the repository asks for it.
            let qa = repository.qa.runInPipeline ? self.qa : nil
            var attempt = 0
            while true {
                let outcome = try await validate(
                    ticketID: ticketID, repository: repository, tools: tools, attempt: attempt,
                    isFinal: { $0.passed ? qa == nil : attempt >= maxFixAttempts }, onEvent: onEvent
                )
                result = outcome
                if !outcome.passed {
                    if attempt >= maxFixAttempts { break }
                    attempt += 1
                    onEvent(.progress("Validation failed. Automatic fix attempt \(attempt) of \(maxFixAttempts)"))
                    _ = try await implementation.implement(
                        ticketID: ticketID, repository: repository, tools: tools,
                        fixInstructions: Self.fixInstructions(for: outcome), onEvent: onEvent
                    )
                    continue
                }
                guard let qa else { break }
                qaResult = try await runQA(qa, ticketID: ticketID, repository: repository, onEvent: onEvent)
                if let qaResult, qaResult.confirmedCount > 0, attempt < maxFixAttempts {
                    attempt += 1
                    onEvent(.progress("QA reproduced \(qaResult.confirmedCount) bug(s). Automatic fix attempt \(attempt) of \(maxFixAttempts)"))
                    _ = try await implementation.implement(
                        ticketID: ticketID, repository: repository, tools: tools,
                        fixInstructions: Self.fixInstructions(forQA: qaResult), onEvent: onEvent
                    )
                    continue
                }
                try await database.transition(ticketID: ticketID, to: .reviewing, message: "Independent review started")
                break
            }
        }
        let latest: ValidationResult
        if let result {
            latest = result
        } else {
            latest = try await latestValidation(ticketID: ticketID)
        }
        let qa = if let qaResult { qaResult } else { try await latestQA(ticketID: ticketID) }
        return try await review(ticketID: ticketID, validation: latest, qa: qa, onEvent: onEvent)
    }

    /// The last QA session, if it tested the current implementation (none ran since).
    private func latestQA(ticketID: String) async throws -> QASessionResult? {
        let runs = try await database.runs(ticketID: ticketID)
        guard let qa = runs.last(where: { $0.qa != nil }) else { return nil }
        let lastImplementation = runs.last { $0.kind == .implementation }
        return (lastImplementation.map { $0.id < qa.id } ?? true) ? qa.qa : nil
    }

    /// Runs and records the pipeline QA session. QA that cannot run (tools missing, the app does
    /// not start, sign-in fails) is recorded as failed and the pipeline goes on to the review:
    /// it never blocks the hand-off. Cancelling still stops everything.
    private func runQA(
        _ qa: any PipelineQA, ticketID: String, repository: RepositoryConfig, onEvent: @escaping @Sendable (RunEvent) -> Void
    ) async throws -> QASessionResult? {
        let runID = try await database.beginVerificationRun(
            .qa, ticketID: ticketID, in: .validating, logPath: artifacts.directory(for: ticketID).appending(path: "qa").path
        )
        onEvent(.started)
        do {
            let result = try await qa.runQA(ticketID: ticketID, repository: repository) { onEvent(.progress($0)) }
            try await database.completeQA(runID: runID, ticketID: ticketID, result: result)
            return result
        } catch is CancellationError {
            await record(CancellationError(), runID: runID, ticketID: ticketID)
            throw CancellationError()
        } catch {
            onEvent(.progress("QA could not run, continuing to the review: \(error.localizedDescription)"))
            await record(error, runID: runID, ticketID: ticketID)
            return nil
        }
    }

    /// Instructions for the implementer when the QA session reproduced bugs.
    public static func fixInstructions(forQA result: QASessionResult) -> String {
        let confirmed = zip(result.report.findings, result.replays).filter { $0.1.status == .confirmed }.map(\.0)
        return "DevPilot's QA session found these bugs in the running app and reproduced each one in a fresh browser. "
            + "Fix their cause; do not special-case the test steps:\n"
            + confirmed.map { finding in
                var lines = [
                    "- \(finding.title) (\(finding.severity.rawValue), page \(finding.pageURL))",
                    "  Expected: \(finding.expected)",
                    "  Actual: \(finding.actual)",
                ]
                if !finding.steps.isEmpty {
                    lines.append("  Steps: " + finding.steps.joined(separator: " → "))
                }
                if !finding.evidence.isEmpty {
                    lines.append("  Evidence: " + String(finding.evidence.prefix(1_500)).replacingOccurrences(of: "\n", with: "\n    "))
                }
                return lines.joined(separator: "\n")
            }.joined(separator: "\n")
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
                environment: ValidationRunner.changeEnvironment(
                    baseCommit: workspace.baseCommit, changedFiles: (try? await worktrees.changedFiles(in: workspace.worktreePath, since: workspace.baseCommit)) ?? []
                ),
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

    private func review(
        ticketID: String, validation: ValidationResult, qa: QASessionResult?, onEvent: @escaping @Sendable (RunEvent) -> Void
    ) async throws -> ReviewReport {
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
                qa: qa,
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
