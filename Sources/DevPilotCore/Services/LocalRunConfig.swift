import Foundation

/// How to run a repository's app locally (unsandboxed, like a developer would), on DevPilot's own
/// ports and a throwaway copy of the database, so it never collides with the user's own run.
///
/// Commands, environment values and the app URL may use placeholders, filled in per run:
/// `{{port.NAME}}` (a free port per service), `{{database}}` (the run's database copy),
/// `{{db.host}}`, `{{db.port}}`, `{{db.user}}`, `{{secret.NAME}}` (from the Keychain) and
/// `{{worktree}}`.
public struct LocalRunConfig: Codable, Sendable, Hashable {
    /// Something that must already be listening, usually a container (Postgres, Redis).
    public struct Dependency: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
        public var port: Int
        /// Run when the port is closed, e.g. `podman compose -f docker-compose.yml up -d db`.
        public var startCommand: String
        public var isEnabled: Bool

        public init(id: String = UUID().uuidString, name: String, port: Int, startCommand: String, isEnabled: Bool = true) {
            self.id = id
            self.name = name
            self.port = port
            self.startCommand = startCommand
            self.isEnabled = isEnabled
        }
    }

    public struct EnvironmentVariable: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var key: String
        public var value: String

        public init(id: String = UUID().uuidString, key: String, value: String) {
            self.id = id
            self.key = key
            self.value = value
        }
    }

    /// A long-running process started from the ticket's worktree.
    public struct Service: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
        /// The `{{port.NAME}}` this service listens on; empty for services without a port (workers).
        public var portName: String
        /// Relative to the worktree.
        public var directory: String
        public var command: String
        public var environment: [EnvironmentVariable]
        /// Ready once an HTTP request to this path gets any response below 500.
        public var readyPath: String
        public var readyTimeoutSeconds: Int
        public var isEnabled: Bool

        public init(
            id: String = UUID().uuidString, name: String, portName: String, directory: String = "", command: String,
            environment: [EnvironmentVariable] = [], readyPath: String = "/", readyTimeoutSeconds: Int = 240, isEnabled: Bool = true
        ) {
            self.id = id
            self.name = name
            self.portName = portName
            self.directory = directory
            self.command = command
            self.environment = environment
            self.readyPath = readyPath
            self.readyTimeoutSeconds = readyTimeoutSeconds
            self.isEnabled = isEnabled
        }
    }

    /// Each run gets `CREATE DATABASE <copy> TEMPLATE <template>`, dropped when the run stops.
    public struct Database: Codable, Sendable, Hashable {
        public var isEnabled = false
        public var host = "localhost"
        public var port = 5432
        public var user = ""
        public var templateName = ""
        /// Name of the repository secret holding the password.
        public var passwordSecret = "db_password"

        public init() {}
    }

    public var dependencies: [Dependency] = []
    public var services: [Service] = []
    /// Untracked files copied from the main checkout for the run (e.g. `.env`) and removed after.
    public var copyFiles: [String] = []
    /// Tracked files the run may rewrite (e.g. `db/structure.sql`, dumped by migrations), put
    /// back as they were when the run stops so they never end up in the branch.
    public var restoreFiles: [String] = []
    public var database = Database()
    public var appURL = ""
    /// Repository secrets (Keychain) referenced as `{{secret.NAME}}`.
    public var secretNames: [String] = []

    public init() {}

    public var isConfigured: Bool { services.contains(where: \.isEnabled) }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        dependencies = try container.decodeIfPresent([Dependency].self, forKey: .dependencies) ?? []
        services = try container.decodeIfPresent([Service].self, forKey: .services) ?? []
        copyFiles = try container.decodeIfPresent([String].self, forKey: .copyFiles) ?? []
        restoreFiles = try container.decodeIfPresent([String].self, forKey: .restoreFiles) ?? []
        database = try container.decodeIfPresent(Database.self, forKey: .database) ?? Database()
        appURL = try container.decodeIfPresent(String.self, forKey: .appURL) ?? ""
        secretNames = try container.decodeIfPresent([String].self, forKey: .secretNames) ?? []
    }
}

/// Fills `{{…}}` placeholders. Unknown placeholders are left as they are so mistakes stay visible.
public struct PlaceholderValues: Sendable {
    public var ports: [String: Int] = [:]
    public var database: String?
    public var databaseConfig = LocalRunConfig.Database()
    public var secrets: [String: String] = [:]
    public var worktree = ""

    public init() {}

    public func resolve(_ text: String) -> String {
        var result = text
        for (name, port) in ports {
            result = result.replacingOccurrences(of: "{{port.\(name)}}", with: String(port))
        }
        if let database {
            result = result.replacingOccurrences(of: "{{database}}", with: database)
        }
        result = result
            .replacingOccurrences(of: "{{db.host}}", with: databaseConfig.host)
            .replacingOccurrences(of: "{{db.port}}", with: String(databaseConfig.port))
            .replacingOccurrences(of: "{{db.user}}", with: databaseConfig.user)
            .replacingOccurrences(of: "{{worktree}}", with: worktree)
        for (name, value) in secrets {
            result = result.replacingOccurrences(of: "{{secret.\(name)}}", with: value)
        }
        return result
    }

    /// Port names a text refers to, so each gets a port even if no service declares it.
    public static func portNames(in text: String) -> Set<String> {
        Set(text.matches(of: /\{\{port\.([A-Za-z0-9_-]+)\}\}/).map { String($0.1) })
    }
}

/// Suggests a local-run configuration from what a repository contains: compose services
/// (dependencies), Rails / Spring Boot / Vite projects (services), Procfile workers (optional),
/// `.env` files to copy, and the database template.
public enum LocalRunPresets {
    public static func detect(repositoryAt path: String) -> (config: LocalRunConfig, secrets: [String: String]) {
        let root = URL(filePath: path, directoryHint: .isDirectory)
        let fileManager = FileManager.default
        func exists(_ relative: String) -> Bool { fileManager.fileExists(atPath: root.appending(path: relative).path) }
        func read(_ relative: String) -> String { (try? String(contentsOf: root.appending(path: relative), encoding: .utf8)) ?? "" }

        var config = LocalRunConfig()
        var secrets: [String: String] = [:]

        // Dependencies from the first compose file.
        let composeFile = ["docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml"].first(where: exists)
        let composeTool = ["/opt/homebrew/bin/podman", "/usr/local/bin/podman"].contains(where: fileManager.isExecutableFile(atPath:))
            ? "podman compose" : "docker compose"
        if let composeFile {
            for service in composeServices(read(composeFile)) {
                guard let port = service.hostPorts.first else { continue }
                let essential = ["db", "postgres", "postgresql", "redis", "mysql", "mongo", "mongodb"].contains(service.name.lowercased())
                config.dependencies.append(LocalRunConfig.Dependency(
                    name: service.name, port: port,
                    startCommand: "\(composeTool) -f \(composeFile) up -d \(service.name)",
                    isEnabled: essential || service.name.lowercased().contains("localstack")
                ))
                if ["db", "postgres", "postgresql"].contains(service.name.lowercased()) {
                    config.database.isEnabled = true
                    config.database.port = port
                    config.database.user = service.environment["POSTGRES_USER"] ?? "postgres"
                    let source = service.environment["POSTGRES_DB"] ?? config.database.user
                    config.database.templateName = "\(source)_devpilot_template"
                    if let password = service.environment["POSTGRES_PASSWORD"] {
                        secrets[config.database.passwordSecret] = password
                    }
                    config.secretNames.append(config.database.passwordSecret)
                }
            }
        }
        let hasRedis = config.dependencies.contains { $0.name.lowercased() == "redis" }
        let databaseURL = "postgres://{{db.user}}:{{secret.\(config.database.passwordSecret)}}@{{db.host}}:{{db.port}}/{{database}}"

        // Back end: Rails or Spring Boot, at the top level or in a project folder.
        let projects = CommandPresets.projectDirectories(in: root) + (exists("Gemfile") ? [""] : [])
        var apiPortName: String?
        for project in Array(Set(projects)).sorted() {
            let prefix = project.isEmpty ? "" : project + "/"
            if exists(prefix + "Gemfile") && exists(prefix + "config/application.rb") {
                var environment = [LocalRunConfig.EnvironmentVariable(key: "RAILS_ENV", value: "development")]
                if config.database.isEnabled { environment.append(.init(key: "DATABASE_URL", value: databaseURL)) }
                if hasRedis { environment.append(.init(key: "REDIS_URL", value: "redis://localhost:6379/5")) }
                config.services.append(LocalRunConfig.Service(
                    name: "api", portName: "api", directory: project,
                    command: "bin/rails db:migrate && bundle exec rails server -p {{port.api}} -b 127.0.0.1",
                    environment: environment
                ))
                apiPortName = "api"
                // Migrations dump the schema again, formatted by the local pg_dump.
                config.restoreFiles += ["db/structure.sql", "db/schema.rb"].map { prefix + $0 }.filter(exists)
                // Procfile background workers: optional, off by default.
                for (name, command) in procfileEntries(read(prefix + "Procfile")) where !["web", "release"].contains(name) {
                    config.services.append(LocalRunConfig.Service(
                        name: name, portName: "", directory: project, command: command,
                        environment: environment, isEnabled: false
                    ))
                }
            } else if read(prefix + "build.gradle").contains("org.springframework.boot")
                        || read(prefix + "build.gradle.kts").contains("org.springframework.boot") {
                let wrapper = exists(prefix + "gradlew") ? "./gradlew" : "gradle"
                config.services.append(LocalRunConfig.Service(
                    name: "api", portName: "api", directory: project,
                    command: "\(wrapper) bootRun --args='--server.port={{port.api}}'"
                ))
                apiPortName = "api"
            }
        }

        // Front end: a package.json with a dev script (not the back end's own folder).
        for project in CommandPresets.projectDirectories(in: root) where !config.services.contains(where: { $0.directory == project }) {
            let prefix = project.isEmpty ? "" : project + "/"
            guard CommandPresets.packageScripts(at: root.appending(path: prefix + "package.json")).contains("dev") else { continue }
            let runner = exists(prefix + "pnpm-lock.yaml") ? "pnpm" : exists(prefix + "yarn.lock") ? "yarn" : "npm"
            var environment: [LocalRunConfig.EnvironmentVariable] = []
            let viteConfig = ["vite.config.ts", "vite.config.js", "vite.config.mts"].map { read(prefix + $0) }.joined()
            if let apiPortName, viteConfig.contains("VITE_API_PROXY_TARGET") {
                environment.append(.init(key: "VITE_API_PROXY_TARGET", value: "http://127.0.0.1:{{port.\(apiPortName)}}"))
            }
            config.services.append(LocalRunConfig.Service(
                name: "web", portName: "web", directory: project,
                command: "\(runner) run dev --port {{port.web}} --strictPort", environment: environment, readyTimeoutSeconds: 120
            ))
            break
        }

        // .env files the worktree lacks (they are untracked): copied for the run, removed after.
        for directory in [""] + CommandPresets.projectDirectories(in: root).filter({ !$0.isEmpty }) {
            let relative = directory.isEmpty ? ".env" : "\(directory)/.env"
            if exists(relative) { config.copyFiles.append(relative) }
        }

        let web = config.services.first { $0.portName == "web" }
        config.appURL = web != nil ? "http://localhost:{{port.web}}" : apiPortName.map { "http://localhost:{{port.\($0)}}" } ?? ""
        addLocalhostOverrides(to: &config, repositoryAt: path)
        return (config, secrets)
    }

    /// `.env` files often point one part of the app at another on its usual port, e.g. a front
    /// end's `VITE_API_BASE_URL=http://localhost:3000`. A run uses its own ports, so each such
    /// variable gets an override on the service that reads that `.env` (process variables win
    /// over `.env` files in Vite and dotenv). When that service's dev server proxies the URL's path
    /// (or the URL is a bare base URL), the override is the service's own address instead: same
    /// origin, so the page's Content Security Policy and CORS allow it, and the proxy reaches the
    /// run's back end. Variables the service already sets are kept. Returns whether anything was added.
    @discardableResult
    public static func addLocalhostOverrides(to config: inout LocalRunConfig, repositoryAt path: String) -> Bool {
        var usualPorts: [Int: String] = [:]
        for service in config.services where !service.portName.isEmpty {
            if service.command.contains("rails server") || service.command.contains("rails s ") {
                usualPorts[3000] = service.portName
            } else if service.command.contains("bootRun") {
                usualPorts[8080] = service.portName
            } else if service.command.contains("run dev") {
                usualPorts[5173] = service.portName
            }
        }
        guard !usualPorts.isEmpty else { return false }
        var changed = false
        for file in config.copyFiles where (file as NSString).lastPathComponent.hasPrefix(".env") {
            let directory = (file as NSString).deletingLastPathComponent
            let values = LocalRunDiagnosis.dotenv(at: URL(filePath: path).appending(path: file))
            for index in config.services.indices where config.services[index].directory == directory {
                let ownPort = config.services[index].portName
                let proxied = proxiedPaths(in: URL(filePath: path).appending(path: directory, directoryHint: .isDirectory))
                for (key, value) in values.sorted(by: { $0.key < $1.key })
                where !config.services[index].environment.contains(where: { $0.key == key }) && !value.contains("@") {
                    guard let match = value.firstMatch(of: /^((?:https?|wss?):\/\/(?:localhost|127\.0\.0\.1)):(\d+)(.*)$/),
                          let port = Int(match.2), var portName = usualPorts[port] else { continue }
                    let urlPath = String(match.3)
                    if !ownPort.isEmpty, portName != ownPort, !proxied.isEmpty,
                       urlPath.isEmpty || urlPath == "/" || proxied.contains(where: { urlPath.hasPrefix($0) }) {
                        portName = ownPort
                    }
                    config.services[index].environment.append(.init(key: key, value: "\(match.1):{{port.\(portName)}}\(urlPath)"))
                    changed = true
                }
            }
        }
        return changed
    }

    /// Path prefixes a Vite dev server proxies (`server.proxy` keys such as `'/api'`).
    static func proxiedPaths(in directory: URL) -> [String] {
        let text = ["vite.config.ts", "vite.config.js", "vite.config.mts"]
            .compactMap { try? String(contentsOf: directory.appending(path: $0), encoding: .utf8) }.joined()
        guard let proxy = text.range(of: "proxy:") else { return [] }
        return text[proxy.upperBound...].matches(of: /['"](\/[A-Za-z0-9_\-\/.]*)['"]\s*:\s*\{/).map { String($0.1) }
    }

    struct ComposeService {
        let name: String
        let hostPorts: [Int]
        let environment: [String: String]
    }

    /// Minimal compose reader: top-level service names, published host ports and literal
    /// environment values. Enough for presets; the user can edit everything.
    static func composeServices(_ yaml: String) -> [ComposeService] {
        guard let start = yaml.range(of: "\nservices:\n") ?? (yaml.hasPrefix("services:\n") ? yaml.range(of: "services:\n") : nil) else {
            return []
        }
        var services: [ComposeService] = []
        var name: String?
        var ports: [Int] = []
        var environment: [String: String] = [:]
        func flush() {
            if let name { services.append(ComposeService(name: name, hostPorts: ports, environment: environment)) }
            name = nil
            ports = []
            environment = [:]
        }
        for line in yaml[start.upperBound...].split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = line.first, !first.isWhitespace, first != "#" { break }  // next top-level key
            if let match = line.wholeMatch(of: /^ {2}([A-Za-z0-9_.-]+):\s*$/) {
                flush()
                name = String(match.1)
            } else if let match = line.firstMatch(of: /^\s+-\s*["']?(?:[\d.]+:)?(\d+):\d+(?:\/\w+)?["']?\s*$/) {
                ports.append(Int(match.1) ?? 0)
            } else if let match = line.firstMatch(of: /^\s+-?\s*([A-Z][A-Z0-9_]*)\s*[:=]\s*["']?([^"'\n#]*?)["']?\s*$/) {
                environment[String(match.1)] = String(match.2)
            }
        }
        flush()
        return services
    }

    /// `name: command` lines; a `bin/start-pgbouncer` wrapper (for hosting platforms) is dropped.
    static func procfileEntries(_ text: String) -> [(String, String)] {
        text.split(separator: "\n").compactMap { line in
            guard let match = line.wholeMatch(of: /([A-Za-z0-9_-]+):\s*(.+)/) else { return nil }
            let command = String(match.2).replacingOccurrences(of: "bin/start-pgbouncer ", with: "")
            return (String(match.1), command)
        }
    }
}
