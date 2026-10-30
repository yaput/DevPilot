import Foundation

/// One test/lint/typecheck command DevPilot ran in the worktree sandbox.
public struct ValidationCommandResult: Codable, Sendable, Hashable {
    public let command: String
    /// Nil when the command was killed (timeout) or terminated by a signal.
    public let exitCode: Int32?
    public let timedOut: Bool
    public let durationSeconds: Double
    /// Full combined output, in the ticket's artifacts folder.
    public let logPath: String
    /// The last lines of output, for display and for fix requests.
    public let outputTail: String

    public var passed: Bool { exitCode == 0 && !timedOut }

    public init(command: String, exitCode: Int32?, timedOut: Bool, durationSeconds: Double, logPath: String, outputTail: String) {
        self.command = command
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.durationSeconds = durationSeconds
        self.logPath = logPath
        self.outputTail = outputTail
    }
}

public struct ValidationResult: Codable, Sendable, Hashable {
    public let commands: [ValidationCommandResult]
    /// 0 for the run after implementation, then 1, 2… after automatic fix attempts.
    public let fixAttempt: Int

    public var passed: Bool { commands.allSatisfy(\.passed) }
    public var failed: [ValidationCommandResult] { commands.filter { !$0.passed } }

    public init(commands: [ValidationCommandResult], fixAttempt: Int) {
        self.commands = commands
        self.fixAttempt = fixAttempt
    }
}

/// Produced by a fresh, read-only agent run comparing the actual changes with the approved plan.
public struct ReviewReport: Codable, Sendable, Hashable {
    public enum Verdict: String, Codable, Sendable {
        case approve
        case changesRequested = "changes_requested"
    }

    public struct Finding: Codable, Sendable, Hashable {
        public enum Severity: String, Codable, Sendable, CaseIterable, Comparable {
            case critical, major, minor, nit

            public static func < (lhs: Self, rhs: Self) -> Bool {
                allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
            }
        }

        public enum Category: String, Codable, Sendable {
            case bug, security, regression
            case missingTest = "missing_test"
            case planDeviation = "plan_deviation"
            case quality
        }

        public let severity: Severity
        public let category: Category
        /// Repository-relative path; empty when the finding is not about one file.
        public let file: String
        /// 1-based line, or 0 when unknown.
        public let line: Int
        public let title: String
        public let detail: String
        public let suggestion: String

        public init(severity: Severity, category: Category, file: String, line: Int, title: String, detail: String, suggestion: String) {
            self.severity = severity
            self.category = category
            self.file = file
            self.line = line
            self.title = title
            self.detail = detail
            self.suggestion = suggestion
        }
    }

    public struct PlanStep: Codable, Sendable, Hashable {
        public enum Status: String, Codable, Sendable {
            case done, partial, missing
        }

        public let step: String
        public let status: Status
        public let note: String

        public init(step: String, status: Status, note: String) {
            self.step = step
            self.status = status
            self.note = note
        }
    }

    public let verdict: Verdict
    public let summary: String
    public let findings: [Finding]
    public let planCoverage: [PlanStep]
    public let testAssessment: String
    public let unresolvedRisks: [String]

    public init(
        verdict: Verdict, summary: String, findings: [Finding], planCoverage: [PlanStep],
        testAssessment: String, unresolvedRisks: [String]
    ) {
        self.verdict = verdict
        self.summary = summary
        self.findings = findings
        self.planCoverage = planCoverage
        self.testAssessment = testAssessment
        self.unresolvedRisks = unresolvedRisks
    }
}

/// Where a ticket's branch stands, for the hand-off screen. Read from git, never changed.
public struct BranchStatus: Sendable, Hashable {
    public let branch: String
    public let commitsSinceBase: Int
    /// Remote-tracking branch, if the branch was pushed with an upstream.
    public let upstream: String?
    /// Commits not yet pushed to `upstream` (all commits when there is no upstream).
    public let unpushedCommits: Int
    /// Uncommitted or untracked files in the worktree; nil if the worktree is gone.
    public let uncommittedFiles: Int?

    public init(branch: String, commitsSinceBase: Int, upstream: String?, unpushedCommits: Int, uncommittedFiles: Int?) {
        self.branch = branch
        self.commitsSinceBase = commitsSinceBase
        self.upstream = upstream
        self.unpushedCommits = unpushedCommits
        self.uncommittedFiles = uncommittedFiles
    }
}
