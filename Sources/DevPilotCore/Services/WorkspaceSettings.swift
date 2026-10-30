import Foundation

/// A command the user has reviewed, with a checkbox.
public struct CommandRule: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var command: String
    public var isEnabled: Bool

    public init(id: String = UUID().uuidString, command: String, isEnabled: Bool = true) {
        self.id = id
        self.command = command
        self.isEnabled = isEnabled
    }
}

public struct RepositoryConfig: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// Absolute path to the repository's top-level directory.
    public var path: String
    /// Branch (or other ref) new ticket worktrees start from.
    public var baseBranch: String
    /// Run by DevPilot (not the agent, with network access) in a fresh worktree before
    /// implementation, e.g. `pnpm install --frozen-lockfile`.
    public var setupCommands: [CommandRule]
    /// Command prefixes the agent may run during implementation, e.g. `./mvnw` or `pnpm`.
    public var agentCommands: [CommandRule]
    /// Full commands DevPilot runs (sandboxed) after implementation to verify the change, e.g.
    /// `cd services/ui && pnpm test`. Each must exit 0 to pass.
    public var validationCommands: [CommandRule]

    public init(
        id: String = UUID().uuidString, name: String, path: String, baseBranch: String,
        setupCommands: [CommandRule] = [], agentCommands: [CommandRule] = [], validationCommands: [CommandRule] = []
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.baseBranch = baseBranch
        self.setupCommands = setupCommands
        self.agentCommands = agentCommands
        self.validationCommands = validationCommands
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        baseBranch = try container.decode(String.self, forKey: .baseBranch)
        setupCommands = try container.decodeIfPresent([CommandRule].self, forKey: .setupCommands) ?? []
        agentCommands = try container.decodeIfPresent([CommandRule].self, forKey: .agentCommands) ?? []
        validationCommands = try container.decodeIfPresent([CommandRule].self, forKey: .validationCommands) ?? []
    }
}

/// Suggested commands for the build tools found in a repository. Everything starts enabled;
/// the user unchecks what they don't want.
public enum CommandPresets {
    /// Read-only git commands the agent may always use to inspect its own changes.
    public static let gitInspection = ["git status", "git diff", "git log", "git show"]

    /// Read-only text tools agents chain onto other commands (`… | tail -5`). Each part of a
    /// pipeline must be allowed, and the sandbox still limits what they can read.
    public static let shellUtilities = ["ls", "cat", "head", "tail", "grep", "wc", "sort"]

    /// Never allowed, whatever the per-repository list says. The sandbox already blocks git
    /// writes and network access; these make the intent explicit for direct invocations.
    public static let alwaysDenied = [
        "git commit", "git push", "git merge", "git rebase", "git reset", "git checkout", "git switch",
        "git branch", "git tag", "git remote", "git config", "git stash", "git cherry-pick", "git worktree",
        "git clean", "git am", "git apply", "git fetch", "git pull", "git clone",
        "npm publish", "pnpm publish", "yarn publish", "npm login", "npm adduser",
        "mvn deploy", "./mvnw deploy", "gradle publish", "./gradlew publish",
        "curl", "wget", "ssh", "scp", "sudo",
    ]

    /// Looks for build files at the top level and up to two folders down (monorepos such as
    /// `services/api` + `services/ui`). Commands for sub-projects `cd` into them first.
    public static func detect(repositoryAt path: String) -> (setup: [CommandRule], agent: [CommandRule], validation: [CommandRule]) {
        let root = URL(filePath: path, directoryHint: .isDirectory)
        var setup: [String] = []
        var agent: [String] = []
        var validation: [String] = []
        func add(_ command: String) {
            if !agent.contains(command) { agent.append(command) }
        }

        for project in projectDirectories(in: root) {
            func has(_ name: String) -> Bool {
                FileManager.default.fileExists(atPath: root.appending(path: project).appending(path: name).path)
            }
            let cd = project.isEmpty ? "" : "cd \(project) && "
            if !project.isEmpty { add("cd") }

            let isJava = has("mvnw") || has("pom.xml") || has("gradlew") || has("build.gradle") || has("build.gradle.kts")
            if has("mvnw") {
                setup.append(cd + "./mvnw -B -q -DskipTests verify")
                validation.append(cd + "./mvnw -B -o test")
                add("./mvnw")
            } else if has("pom.xml") {
                setup.append(cd + "mvn -B -q -DskipTests verify")
                validation.append(cd + "mvn -B -o test")
                add("mvn")
            }
            if has("gradlew") {
                setup.append(cd + "./gradlew --no-daemon -q testClasses")
                validation.append(cd + "./gradlew --no-daemon --offline test")
                add("./gradlew")
            } else if has("build.gradle") || has("build.gradle.kts") {
                setup.append(cd + "gradle --no-daemon -q testClasses")
                validation.append(cd + "gradle --no-daemon --offline test")
                add("gradle")
            }
            if isJava { add("java") }
            if has("package.json") {
                let runner: String
                if has("pnpm-lock.yaml") {
                    setup.append(cd + "pnpm install --frozen-lockfile")
                    add("pnpm")
                    runner = "pnpm run"
                } else if has("yarn.lock") {
                    setup.append(cd + "yarn install --frozen-lockfile")
                    add("yarn")
                    runner = "yarn run"
                } else {
                    setup.append(cd + (has("package-lock.json") ? "npm ci" : "npm install"))
                    add("npm")
                    runner = "npm run"
                }
                add("npx")
                add("node")
                let scripts = packageScripts(at: root.appending(path: project).appending(path: "package.json"))
                for script in ["typecheck", "type-check", "check-types", "lint", "test"] where scripts.contains(script) {
                    validation.append(cd + "\(runner) \(script)")
                }
            }
        }
        (gitInspection + shellUtilities).forEach(add)
        return (
            setup.map { CommandRule(command: $0) },
            agent.map { CommandRule(command: $0) },
            validation.map { CommandRule(command: $0) }
        )
    }

    /// Script names declared in a package.json; empty if it can't be read.
    static func packageScripts(at url: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let scripts)? = json["scripts"] else { return [] }
        return Set(scripts.keys)
    }

    private static let buildFiles = [
        "mvnw", "pom.xml", "gradlew", "build.gradle", "build.gradle.kts", "package.json",
    ]
    private static let skippedFolders: Set<String> = [
        "node_modules", "build", "dist", "target", "out", "vendor", "docs", "test", "tests", "src",
    ]

    /// Relative paths of folders that hold a build file: "" for the top level, then up to two
    /// levels down. A project's own sub-folders (e.g. Gradle modules) are not listed separately.
    public static func projectDirectories(in root: URL) -> [String] {
        let fileManager = FileManager.default
        func isProject(_ relative: String) -> Bool {
            buildFiles.contains { fileManager.fileExists(atPath: root.appending(path: relative).appending(path: $0).path) }
        }
        func subfolders(_ relative: String) -> [String] {
            let url = relative.isEmpty ? root : root.appending(path: relative)
            let names = (try? fileManager.contentsOfDirectory(atPath: url.path)) ?? []
            return names.sorted().filter { name in
                var isDirectory: ObjCBool = false
                return !name.hasPrefix(".") && !skippedFolders.contains(name)
                    && fileManager.fileExists(atPath: url.appending(path: name).path, isDirectory: &isDirectory) && isDirectory.boolValue
            }.map { relative.isEmpty ? $0 : "\(relative)/\($0)" }
        }
        if isProject("") { return [""] }
        var projects: [String] = []
        for first in subfolders("") {
            if isProject(first) {
                projects.append(first)
                continue
            }
            projects += subfolders(first).filter(isProject)
        }
        return projects
    }
}

/// Routes tickets to a repository. Jira rules can match a project key; a rule with an empty
/// key is the default for every ticket from that provider.
public struct RepositoryRule: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var provider: TicketProviderKind
    public var projectKey: String
    public var repositoryID: String

    public init(id: String = UUID().uuidString, provider: TicketProviderKind, projectKey: String = "", repositoryID: String) {
        self.id = id
        self.provider = provider
        self.projectKey = projectKey
        self.repositoryID = repositoryID
    }
}

public struct WorkspaceSettings: StoredSettings {
    public static let storageKey = "workspaceSettings"
    public static let defaultWorktreeRoot = "~/DevPilot/worktrees"

    public var repositories: [RepositoryConfig] = []
    public var rules: [RepositoryRule] = []
    public var worktreeRoot = Self.defaultWorktreeRoot
    /// Bundle identifier of the app used for "Open in…". Empty means the first one installed.
    public var editorBundleID = ""
    /// Bumped when new kinds of per-repository presets are introduced, so existing repositories
    /// are filled in once (and never again, so the user can clear a list).
    public var presetsVersion = 0

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        repositories = try container.decodeIfPresent([RepositoryConfig].self, forKey: .repositories) ?? repositories
        rules = try container.decodeIfPresent([RepositoryRule].self, forKey: .rules) ?? rules
        worktreeRoot = try container.decodeIfPresent(String.self, forKey: .worktreeRoot) ?? worktreeRoot
        editorBundleID = try container.decodeIfPresent(String.self, forKey: .editorBundleID) ?? editorBundleID
        presetsVersion = try container.decodeIfPresent(Int.self, forKey: .presetsVersion) ?? presetsVersion
    }

    public func repository(id: String) -> RepositoryConfig? {
        repositories.first { $0.id == id }
    }

    public var resolvedWorktreeRoot: URL {
        let path = (worktreeRoot.isEmpty ? Self.defaultWorktreeRoot : worktreeRoot) as NSString
        return URL(filePath: path.expandingTildeInPath, directoryHint: .isDirectory).standardizedFileURL
    }

    /// Project-key rule, then provider default, then the only repository if there is just one.
    public func suggestedRepository(for ticket: Ticket) -> RepositoryConfig? {
        let key = Self.projectKey(of: ticket)
        let providerRules = rules.filter { $0.provider == ticket.provider }
        let match = providerRules.first { !$0.projectKey.isEmpty && $0.projectKey.caseInsensitiveCompare(key ?? "") == .orderedSame }
            ?? providerRules.first { $0.projectKey.isEmpty }
        if let match, let repository = repository(id: match.repositoryID) {
            return repository
        }
        return repositories.count == 1 ? repositories[0] : nil
    }

    /// `PLAT-182` → `PLAT`. Shortcut stories have no project key.
    public static func projectKey(of ticket: Ticket) -> String? {
        guard ticket.provider == .jira, let dash = ticket.externalID.lastIndex(of: "-") else { return nil }
        return String(ticket.externalID[..<dash])
    }
}

public struct AgentSettings: StoredSettings {
    public static let storageKey = "agentSettings"

    /// Path to the `claude` executable. Empty means auto-detect.
    public var claudePath = ""
    /// Model alias or ID. Empty means the account default.
    public var model = ""
    public var investigationTimeoutMinutes = 20
    public var implementationTimeoutMinutes = 30
    /// Per validation command.
    public var validationTimeoutMinutes = 20
    /// How many times Claude may automatically try to fix failing validation before hand-off.
    public var automaticFixAttempts = 1
    /// PATH and JAVA_HOME for build tools, imported from the login shell (GUI apps don't get them).
    public var toolPath = ""
    public var javaHome = ""

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        claudePath = try container.decodeIfPresent(String.self, forKey: .claudePath) ?? claudePath
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? model
        investigationTimeoutMinutes = try container.decodeIfPresent(Int.self, forKey: .investigationTimeoutMinutes) ?? investigationTimeoutMinutes
        implementationTimeoutMinutes = try container.decodeIfPresent(Int.self, forKey: .implementationTimeoutMinutes) ?? implementationTimeoutMinutes
        validationTimeoutMinutes = try container.decodeIfPresent(Int.self, forKey: .validationTimeoutMinutes) ?? validationTimeoutMinutes
        automaticFixAttempts = try container.decodeIfPresent(Int.self, forKey: .automaticFixAttempts) ?? automaticFixAttempts
        toolPath = try container.decodeIfPresent(String.self, forKey: .toolPath) ?? toolPath
        javaHome = try container.decodeIfPresent(String.self, forKey: .javaHome) ?? javaHome
    }

    public var toolEnvironment: ToolEnvironment {
        ToolEnvironment(path: toolPath, javaHome: javaHome)
    }
}
