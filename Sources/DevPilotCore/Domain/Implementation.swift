import Foundation

/// The agent's own account of an implementation run, produced against a JSON schema.
public struct ImplementationReport: Codable, Sendable, Hashable {
    public enum Outcome: String, Codable, Sendable {
        /// Every plan step is done.
        case completed
        /// Some steps are done; `remainingWork` lists the rest.
        case partial
        /// Could not proceed (e.g. a dependency is missing and the network is off).
        case blocked
    }

    public struct CommandResult: Codable, Sendable, Hashable {
        public let command: String
        public let succeeded: Bool
        public let note: String

        public init(command: String, succeeded: Bool, note: String) {
            self.command = command
            self.succeeded = succeeded
            self.note = note
        }
    }

    public let outcome: Outcome
    public let summary: String
    public let completedSteps: [String]
    /// Anything done differently from the approved plan, with the reason.
    public let deviations: [String]
    public let commands: [CommandResult]
    public let remainingWork: [String]
    public let notesForReviewer: [String]

    public init(
        outcome: Outcome, summary: String, completedSteps: [String], deviations: [String],
        commands: [CommandResult], remainingWork: [String], notesForReviewer: [String]
    ) {
        self.outcome = outcome
        self.summary = summary
        self.completedSteps = completedSteps
        self.deviations = deviations
        self.commands = commands
        self.remainingWork = remainingWork
        self.notesForReviewer = notesForReviewer
    }
}

/// A file the implementation changed, as reported by `git status` in the worktree.
public struct ChangedFile: Codable, Sendable, Hashable {
    public enum Change: String, Codable, Sendable {
        case added, modified, deleted, renamed, untracked, other
    }

    public let path: String
    public let change: Change

    public init(path: String, change: Change) {
        self.path = path
        self.change = change
    }
}

/// What DevPilot records for a finished implementation run: the agent's report plus facts
/// DevPilot verified itself.
public struct ImplementationResult: Codable, Sendable, Hashable {
    public let report: ImplementationReport
    public let changedFiles: [ChangedFile]
    public let planVersion: Int

    public init(report: ImplementationReport, changedFiles: [ChangedFile], planVersion: Int) {
        self.report = report
        self.changedFiles = changedFiles
        self.planVersion = planVersion
    }
}
