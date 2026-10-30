import Foundation
import Testing
@testable import DevPilotCore

struct UnifiedDiffParserTests {
    @Test func modifiedFileWithLineNumbers() throws {
        let patch = """
            diff --git a/src/app.js b/src/app.js
            index 1111111..2222222 100644
            --- a/src/app.js
            +++ b/src/app.js
            @@ -10,3 +10,4 @@ function main() {
             const a = 1;
            -const b = 2;
            +const b = 3;
            +const c = 4;
             return a;
            """
        let file = try #require(UnifiedDiffParser.parse(patch).first)
        #expect(file.path == "src/app.js")
        #expect(file.change == .modified)
        #expect(file.additions == 2 && file.deletions == 1)
        #expect(file.lines.map(\.kind) == [.hunkHeader, .context, .deletion, .addition, .addition, .context])
        #expect(file.lines[1].oldNumber == 10 && file.lines[1].newNumber == 10)
        #expect(file.lines[2].oldNumber == 11 && file.lines[2].newNumber == nil)
        #expect(file.lines[4].newNumber == 12)
        #expect(file.lines[5].oldNumber == 12 && file.lines[5].newNumber == 13)
    }

    @Test func addedDeletedRenamedAndBinaryFiles() {
        let patch = """
            diff --git a/new.txt b/new.txt
            new file mode 100644
            --- /dev/null
            +++ b/new.txt
            @@ -0,0 +1 @@
            +hello
            \\ No newline at end of file
            diff --git a/old.txt b/old.txt
            deleted file mode 100644
            --- a/old.txt
            +++ /dev/null
            @@ -1 +0,0 @@
            -bye
            diff --git a/a dir/x.swift b/a dir/y.swift
            similarity index 90%
            rename from a dir/x.swift
            rename to a dir/y.swift
            diff --git a/logo.png b/logo.png
            Binary files a/logo.png and b/logo.png differ
            """
        let files = UnifiedDiffParser.parse(patch)
        #expect(files.map(\.path) == ["new.txt", "old.txt", "a dir/y.swift", "logo.png"])
        #expect(files.map(\.change) == [.added, .deleted, .renamed, .modified])
        #expect(files[0].lines.last?.kind == .note)
        #expect(files[2].oldPath == "a dir/x.swift")
        #expect(files[3].isBinary)
    }

    @Test func emptyPatchHasNoFiles() {
        #expect(UnifiedDiffParser.parse("").isEmpty)
    }
}

struct WorktreeDiffTests {
    @Test func includesCommittedUncommittedAndNewFilesButNotIgnoredOnes() async throws {
        let repo = try await TestRepository(files: ["README.md": "# Test\n", "a.txt": "one\n", "b.txt": "keep\n", ".gitignore": "build/\n"])
        defer { repo.remove() }
        let workspace = try await repo.manager.prepareWorktree(for: .sample(), repository: repo.config)
        let worktree = URL(filePath: workspace.worktreePath, directoryHint: .isDirectory)
        try "one\ntwo\n".write(to: worktree.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: worktree.appending(path: "b.txt"))
        try FileManager.default.createDirectory(at: worktree.appending(path: "src"), withIntermediateDirectories: true)
        try "brand new\n".write(to: worktree.appending(path: "src/new file.swift"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: worktree.appending(path: "build"), withIntermediateDirectories: true)
        try "ignored\n".write(to: worktree.appending(path: "build/out.txt"), atomically: true, encoding: .utf8)
        // A change the user already committed still shows: the diff is against the base commit.
        try "# Test\nCommitted line\n".write(to: worktree.appending(path: "README.md"), atomically: true, encoding: .utf8)
        try await repo.git("add", "README.md", in: worktree)
        try await repo.git("-c", "user.email=a@b", "-c", "user.name=u", "commit", "-qm", "docs", in: worktree)

        let files = try await repo.manager.diff(in: workspace.worktreePath, against: workspace.baseCommit)

        #expect(files.map(\.path) == ["a.txt", "b.txt", "README.md", "src/new file.swift"])
        let byPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
        #expect(byPath["a.txt"]?.change == .modified)
        #expect(byPath["a.txt"]?.additions == 1)
        #expect(byPath["b.txt"]?.change == .deleted)
        #expect(byPath["README.md"]?.lines.contains { $0.kind == .addition && $0.text == "Committed line" } == true)
        #expect(byPath["src/new file.swift"]?.change == .untracked)
        #expect(byPath["src/new file.swift"]?.lines.contains { $0.text == "brand new" } == true)
    }
}
