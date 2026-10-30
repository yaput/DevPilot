import Foundation

/// One file's changes, parsed from a unified diff for display.
public struct FileDiff: Sendable, Hashable, Identifiable {
    public struct Line: Sendable, Hashable {
        public enum Kind: Sendable, Hashable {
            case context, addition, deletion, hunkHeader, note
        }

        public let kind: Kind
        public let text: String
        public let oldNumber: Int?
        public let newNumber: Int?
    }

    public var id: String { path }
    public let path: String
    /// Set for renames.
    public let oldPath: String?
    public let change: ChangedFile.Change
    public let lines: [Line]
    public let additions: Int
    public let deletions: Int
    public let isBinary: Bool
    /// Lines beyond `UnifiedDiffParser.maxLinesPerFile` were dropped.
    public let isTruncated: Bool

    func with(change: ChangedFile.Change) -> FileDiff {
        FileDiff(
            path: path, oldPath: oldPath, change: change, lines: lines, additions: additions,
            deletions: deletions, isBinary: isBinary, isTruncated: isTruncated
        )
    }
}

public enum UnifiedDiffParser {
    public static let maxLinesPerFile = 5000

    /// Parses `git diff` output (with `a/` and `b/` prefixes) into per-file diffs.
    public static func parse(_ patch: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var current: Builder?

        for raw in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("diff --git ") || line.hasPrefix("diff --cc ") {
                if let finished = current?.build() { files.append(finished) }
                current = Builder(header: line)
                continue
            }
            current?.consume(line)
        }
        if let finished = current?.build() { files.append(finished) }
        return files
    }

    private struct Builder {
        var oldPath: String?
        var newPath: String?
        var headerPath: String
        var change: ChangedFile.Change = .modified
        var lines: [FileDiff.Line] = []
        var additions = 0
        var deletions = 0
        var isBinary = false
        var isTruncated = false
        var inHunk = false
        var oldLine = 0
        var newLine = 0

        init(header: String) {
            // "diff --git a/x b/x": a fallback only; ---/+++ lines are authoritative.
            let parts = header.components(separatedBy: " b/")
            headerPath = parts.count > 1 ? parts.last! : header
        }

        mutating func consume(_ line: String) {
            if !inHunk {
                if line.hasPrefix("new file mode") { change = .added }
                else if line.hasPrefix("deleted file mode") { change = .deleted }
                else if line.hasPrefix("rename from ") { change = .renamed; oldPath = String(line.dropFirst("rename from ".count)) }
                else if line.hasPrefix("rename to ") { newPath = String(line.dropFirst("rename to ".count)) }
                else if line.hasPrefix("Binary files ") { isBinary = true }
                else if line.hasPrefix("--- ") { oldPath = oldPath ?? Self.path(from: line) }
                else if line.hasPrefix("+++ ") { newPath = Self.path(from: line) ?? newPath }
                else if line.hasPrefix("@@") { startHunk(line) }
                return
            }
            if line.hasPrefix("@@") {
                startHunk(line)
            } else if line.hasPrefix("+") {
                append(.addition, String(line.dropFirst()), old: nil, new: newLine)
                newLine += 1
                additions += 1
            } else if line.hasPrefix("-") {
                append(.deletion, String(line.dropFirst()), old: oldLine, new: nil)
                oldLine += 1
                deletions += 1
            } else if line.hasPrefix(" ") {
                append(.context, String(line.dropFirst()), old: oldLine, new: newLine)
                oldLine += 1
                newLine += 1
            } else if line.hasPrefix("\\") {
                append(.note, String(line.dropFirst(2)), old: nil, new: nil)
            }
        }

        private mutating func startHunk(_ line: String) {
            inHunk = true
            if let match = line.firstMatch(of: /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/) {
                oldLine = Int(match.1) ?? 0
                newLine = Int(match.2) ?? 0
            }
            append(.hunkHeader, line, old: nil, new: nil)
        }

        private mutating func append(_ kind: FileDiff.Line.Kind, _ text: String, old: Int?, new: Int?) {
            guard lines.count < UnifiedDiffParser.maxLinesPerFile else {
                isTruncated = true
                return
            }
            lines.append(FileDiff.Line(kind: kind, text: text, oldNumber: old, newNumber: new))
        }

        /// "--- a/src/x.swift", "+++ b/src/x.swift" or "/dev/null"; git may append a tab.
        private static func path(from line: String) -> String? {
            let value = String(line.dropFirst(4)).components(separatedBy: "\t")[0]
            if value == "/dev/null" { return nil }
            if value.hasPrefix("a/") || value.hasPrefix("b/") { return String(value.dropFirst(2)) }
            return value
        }

        func build() -> FileDiff {
            let path = newPath ?? oldPath ?? headerPath
            return FileDiff(
                path: path, oldPath: change == .renamed ? oldPath : nil, change: change, lines: lines,
                additions: additions, deletions: deletions, isBinary: isBinary, isTruncated: isTruncated
            )
        }
    }
}

extension GitWorktreeManager {
    static let maxUntrackedFilesInDiff = 300

    /// Everything that differs from `base` in the worktree: committed and uncommitted changes to
    /// tracked files, plus new untracked files (ignored files excluded). Read-only.
    public func diff(in worktree: String, against base: String) async throws -> [FileDiff] {
        let directory = URL(filePath: worktree, directoryHint: .isDirectory)
        let options = ["-c", "core.quotepath=false", "diff", "--no-color", "--no-ext-diff", "-M", "--src-prefix=a/", "--dst-prefix=b/"]
        var files = UnifiedDiffParser.parse(try await run(options + [base, "--"], in: directory, trimming: false))

        let untracked = try await run(["ls-files", "--others", "--exclude-standard", "-z"], in: directory, trimming: false)
            .split(separator: "\0").map(String.init)
        for path in untracked.prefix(Self.maxUntrackedFilesInDiff) {
            // `--no-index` exits 1 when the files differ, which is always the case here.
            let result = try await ProcessRunner.run(ProcessRequest(
                executable: git, arguments: options + ["--no-index", "--", "/dev/null", path],
                workingDirectory: directory, environment: Self.environment(), timeout: .seconds(60)
            ))
            guard result.termination == .exited(1) || result.termination == .exited(0) else { continue }
            files += UnifiedDiffParser.parse(result.stdoutText).map { $0.with(change: .untracked) }
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
