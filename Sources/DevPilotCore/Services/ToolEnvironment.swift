import Foundation

/// Environment for build tools run in a worktree, by DevPilot (setup) or by the agent.
/// Built from scratch: only these variables plus the basics in `base`, never DevPilot's own.
public struct ToolEnvironment: Sendable, Equatable {
    public static let systemPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    public var path: String
    public var javaHome: String

    public init(path: String, javaHome: String) {
        self.path = path
        self.javaHome = javaHome
    }

    /// `base` plus PATH, JAVA_HOME and flags that keep tools non-interactive and quiet.
    public func variables(base: [String: String]) -> [String: String] {
        var variables = base
        var entries: [String] = []
        for entry in (path + ":" + Self.systemPath).split(separator: ":").map(String.init) where !entry.isEmpty && !entries.contains(entry) {
            entries.append(entry)
        }
        variables["PATH"] = entries.joined(separator: ":")
        if !javaHome.isEmpty {
            variables["JAVA_HOME"] = javaHome
        }
        variables["CI"] = "true"
        // Gradle daemons detach from their parent, so they would outlive the run.
        variables["GRADLE_OPTS"] = "-Dorg.gradle.daemon=false"
        variables["NO_UPDATE_NOTIFIER"] = "1"
        variables["npm_config_update_notifier"] = "false"
        return variables
    }

    /// Reads PATH and JAVA_HOME from the user's login shell, the way Terminal would see them.
    /// Only those two values are kept; nothing else from the shell profile is read.
    public static func importFromLoginShell(shell: String? = nil) async throws -> ToolEnvironment {
        let inherited = ProcessInfo.processInfo.environment
        let shell = shell ?? inherited["SHELL"] ?? "/bin/zsh"
        let marker = "__DEVPILOT_ENV__"
        let result = try await ProcessRunner.run(ProcessRequest(
            executable: URL(filePath: shell),
            arguments: ["-l", "-i", "-c", #"printf '\n\#(marker)%s\#(marker)%s\#(marker)\n' "$PATH" "${JAVA_HOME:-}""#],
            workingDirectory: URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory),
            environment: [
                "HOME": inherited["HOME"] ?? NSHomeDirectory(), "USER": inherited["USER"] ?? NSUserName(),
                "LOGNAME": inherited["LOGNAME"] ?? NSUserName(), "SHELL": shell, "TERM": "dumb", "LANG": "en_US.UTF-8",
            ],
            timeout: .seconds(20)
        ))
        guard let parsed = parse(result.stdoutText, marker: marker) else {
            throw ProcessRunnerError.launchFailed("\(shell) did not report its environment", errno: 0)
        }
        return parsed
    }

    static func parse(_ output: String, marker: String) -> ToolEnvironment? {
        let parts = output.components(separatedBy: marker)
        guard parts.count >= 4 else { return nil }
        let path = parts[parts.count - 3]
        return path.isEmpty ? nil : ToolEnvironment(path: path, javaHome: parts[parts.count - 2])
    }
}
