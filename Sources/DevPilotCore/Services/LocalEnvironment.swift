import Darwin
import Foundation

public enum LocalRunError: Error, Equatable, LocalizedError {
    case notConfigured
    case alreadyRunning(String)
    case dependencyUnavailable(name: String, port: Int, detail: String)
    case toolMissing(String)
    case database(String)
    case serviceFailed(name: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "This repository has no local-run services. Set them up in Settings → Repositories → Local Run."
        case .alreadyRunning(let ticket): "A local run for \(ticket) is active. Stop it first."
        case .dependencyUnavailable(let name, let port, let detail): "\(name) is not reachable on port \(port). \(detail)"
        case .toolMissing(let tool): "\(tool) was not found on the build tools PATH (Settings → Agent)."
        case .database(let detail): "Database copy failed: \(detail)"
        case .serviceFailed(let name, let detail): "Service \(name) failed: \(detail)"
        }
    }
}

public struct LocalRunStatus: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case starting(String)
        case running
        case stopping
        case stopped
        case failed(String)
    }

    public struct Service: Sendable, Equatable, Identifiable {
        public enum State: Sendable, Equatable {
            case waiting, starting, ready, running, failed(String), stopped
        }

        public var id: String { name }
        public let name: String
        public let port: Int?
        public var state: State
        public let logPath: String
    }

    public let runID: String
    public let ticketID: String
    public var phase: Phase
    public var database: String?
    public var appURL: String?
    public var services: [Service]
    public let logDirectory: String
    /// Problems that did not stop the run, such as a failed optional setup command.
    public var warnings: [String] = []

    /// Sign-in output for QA; its `private` folder (the session) is removed when the run stops.
    public var qaLoginDirectory: URL {
        URL(filePath: logDirectory, directoryHint: .isDirectory).appending(path: "qa-login", directoryHint: .isDirectory)
    }
}

/// Runs a repository's app locally for one ticket at a time: unsandboxed, from the ticket's
/// worktree, on free ports, against a throwaway database copy. Everything it creates is
/// recorded on disk first, so a crash is cleaned up on the next launch.
public actor LocalEnvironment {
    private struct Session {
        var status: LocalRunStatus
        var processes: [(name: String, process: BackgroundProcess)] = []
        var copiedFiles: [URL] = []
        /// Worktree file → its saved copy, put back on teardown.
        var savedFiles: [(file: URL, copy: URL)] = []
        var database: (name: String, config: LocalRunConfig.Database, password: String?)?
        var tools: ToolEnvironment
    }

    /// What `cleanUpLeftovers` needs after a crash.
    private struct RegistryEntry: Codable {
        var runID: String
        var ticketID: String
        var repositoryID: String
        var database: String?
        var databaseConfig: LocalRunConfig.Database?
        var copiedFiles: [String] = []
        /// Worktree file path → saved copy path.
        var savedFiles: [String: String] = [:]
        var processGroups: [Int32] = []
        /// When the services started; identifies leftover process groups after a crash.
        var startedAt = Date()
    }

    private let stateDirectory: URL
    private var session: Session?
    private var observer: (@Sendable (LocalRunStatus) -> Void)?

    public init(stateDirectory: URL) {
        self.stateDirectory = stateDirectory
    }

    public var status: LocalRunStatus? { session?.status }

    private var registryURL: URL { stateDirectory.appending(path: "local-run.json") }

    // MARK: - Start

    public func start(
        ticketID: String,
        repositoryID: String,
        worktree: String,
        mainCheckout: String,
        config: LocalRunConfig,
        setupCommands: [String] = [],
        /// Setup commands whose failure is only a warning.
        optionalSetupCommands: Set<String> = [],
        secrets: [String: String],
        tools: ToolEnvironment,
        onStatus: @escaping @Sendable (LocalRunStatus) -> Void
    ) async throws -> LocalRunStatus {
        if let session { throw LocalRunError.alreadyRunning(session.status.ticketID) }
        let services = config.services.filter(\.isEnabled)
        guard !services.isEmpty else { throw LocalRunError.notConfigured }

        let runID = String(UUID().uuidString.prefix(8)).lowercased()
        let logDirectory = stateDirectory.appending(path: "local-runs/\(runID)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)

        var values = PlaceholderValues()
        values.databaseConfig = config.database
        values.secrets = secrets
        values.worktree = worktree
        var portNames = Set(services.map(\.portName).filter { !$0.isEmpty })
        for text in services.flatMap({ [$0.command] + $0.environment.map(\.value) }) + [config.appURL] {
            portNames.formUnion(PlaceholderValues.portNames(in: text))
        }
        values.ports = try Self.freePorts(count: portNames.count).enumerated().reduce(into: [:]) { result, item in
            result[portNames.sorted()[item.offset]] = item.element
        }

        session = Session(
            status: LocalRunStatus(
                runID: runID, ticketID: ticketID, phase: .starting("Checking dependencies"), database: nil,
                appURL: config.appURL.isEmpty ? nil : values.resolve(config.appURL),
                services: services.map { service in
                    .init(name: service.name, port: service.portName.isEmpty ? nil : values.ports[service.portName],
                          state: .waiting, logPath: logDirectory.appending(path: "\(Self.fileName(service.name)).log").path)
                },
                logDirectory: logDirectory.path
            ),
            tools: tools
        )
        observer = onStatus
        var registry = RegistryEntry(runID: runID, ticketID: ticketID, repositoryID: repositoryID)
        try saveRegistry(registry)
        report()

        do {
            for dependency in config.dependencies where dependency.isEnabled {
                try await ensure(dependency, tools: tools, logDirectory: logDirectory)
            }

            if config.database.isEnabled {
                setPhase(.starting("Copying database \(config.database.templateName)"))
                let name = Self.databaseName(ticketID: ticketID, runID: runID)
                registry.database = name
                registry.databaseConfig = config.database
                try saveRegistry(registry)
                let password = secrets[config.database.passwordSecret]
                try await Self.postgres(
                    "createdb", ["-T", config.database.templateName, name], config: config.database, password: password, tools: tools
                )
                session?.database = (name, config.database, password)
                session?.status.database = name
                values.database = name
            }

            for relative in config.copyFiles {
                let source = URL(filePath: mainCheckout).appending(path: relative)
                let target = URL(filePath: worktree).appending(path: relative)
                guard FileManager.default.fileExists(atPath: source.path), !FileManager.default.fileExists(atPath: target.path) else { continue }
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source, to: target)
                session?.copiedFiles.append(target)
                registry.copiedFiles.append(target.path)
                try saveRegistry(registry)
            }

            for relative in config.restoreFiles {
                let file = URL(filePath: worktree).appending(path: relative)
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                let copy = logDirectory.appending(path: "saved/\(relative)")
                try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: file, to: copy)
                session?.savedFiles.append((file, copy))
                registry.savedFiles[file.path] = copy.path
                try saveRegistry(registry)
            }

            // Dependencies a fresh worktree lacks (node_modules, gems); quick when up to date.
            for (index, command) in setupCommands.enumerated() {
                setPhase(.starting("Setup: \(command)"))
                let result = try await ProcessRunner.run(ProcessRequest(
                    executable: URL(filePath: "/bin/sh"), arguments: ["-c", command],
                    workingDirectory: URL(filePath: worktree, directoryHint: .isDirectory),
                    environment: tools.variables(base: ClaudeCodeRunner.environment()), timeout: .seconds(1200)
                ))
                try? (result.stdoutText + result.stderrText).write(
                    to: logDirectory.appending(path: "setup-\(index + 1).log"), atomically: true, encoding: .utf8
                )
                guard result.succeeded else {
                    let tail = (result.stderrText.isEmpty ? result.stdoutText : result.stderrText).suffix(400)
                    if optionalSetupCommands.contains(command) {
                        session?.status.warnings.append("Optional setup `\(command)` failed (log: setup-\(index + 1).log); continued.")
                        report()
                        continue
                    }
                    let hint = LocalRunDiagnosis.hint(forLog: result.stdoutText + result.stderrText).map { "\n\($0)" } ?? ""
                    throw LocalRunError.serviceFailed(name: "setup", detail: "`\(command)` failed: \(tail)\(hint)")
                }
            }

            for (index, service) in services.enumerated() {
                setPhase(.starting("Starting \(service.name)"))
                session?.status.services[index].state = .starting
                report()
                var environment = tools.variables(base: ClaudeCodeRunner.environment())
                environment["CI"] = nil
                for variable in service.environment where !variable.key.isEmpty {
                    environment[variable.key] = values.resolve(variable.value)
                }
                let directory = URL(filePath: worktree).appending(path: service.directory, directoryHint: .isDirectory)
                // The trailing argument becomes the shell's $0, which names the run in `ps` output.
                let process = try ProcessRunner.start(
                    executable: URL(filePath: "/bin/sh"),
                    arguments: ["-c", values.resolve(service.command), "devpilot-run-\(runID)"],
                    workingDirectory: directory,
                    environment: environment,
                    logURL: URL(filePath: session!.status.services[index].logPath)
                )
                session?.processes.append((service.name, process))
                registry.processGroups.append(process.pid)
                try saveRegistry(registry)

                // The service's .env names things like the AWS profile, for failure hints.
                let hintEnvironment = LocalRunDiagnosis.dotenv(at: directory.appending(path: ".env"))
                    .merging(environment) { _, explicit in explicit }
                try await waitUntilReady(
                    service, process: process, port: session?.status.services[index].port, environment: hintEnvironment
                )
                session?.status.services[index].state = service.portName.isEmpty ? .running : .ready
                report()
            }
            setPhase(.running)
            return session!.status
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            if let index = session?.status.services.firstIndex(where: { $0.state == .starting }) {
                session?.status.services[index].state = .failed(message)
            }
            await tearDown(finalPhase: .failed(message))
            throw error
        }
    }

    // MARK: - Stop

    public func stop() async {
        guard session != nil else { return }
        setPhase(.stopping)
        await tearDown(finalPhase: .stopped)
    }

    /// Stops processes (newest first), removes copied files and drops the database copy.
    /// The last status reported keeps `finalPhase` (stopped, or failed with the reason).
    private func tearDown(finalPhase: LocalRunStatus.Phase) async {
        guard var current = session else { return }
        for (name, process) in current.processes.reversed() {
            await process.terminate()
            if let index = current.status.services.firstIndex(where: { $0.name == name }) {
                if case .failed = current.status.services[index].state { continue }
                current.status.services[index].state = .stopped
            }
        }
        for file in current.copiedFiles {
            try? FileManager.default.removeItem(at: file)
        }
        for (file, copy) in current.savedFiles {
            Self.restore(file, from: copy)
        }
        try? FileManager.default.removeItem(at: current.status.qaLoginDirectory.appending(path: "private"))
        if let database = current.database {
            try? await Self.postgres(
                "dropdb", ["--force", "--if-exists", database.name], config: database.config, password: database.password, tools: current.tools
            )
        }
        current.status.phase = finalPhase
        session = current
        report()
        session = nil
        observer = nil
        try? FileManager.default.removeItem(at: registryURL)
    }

    /// Puts a saved file back; the copy is kept with the run's logs.
    private static func restore(_ file: URL, from copy: URL) {
        guard let data = try? Data(contentsOf: copy) else { return }
        try? data.write(to: file, options: .atomic)
    }

    // MARK: - Crash recovery

    /// After a crash: stops leftover services (only process groups still marked as ours),
    /// removes copied files and drops the database copy. `secret` looks up a repository secret.
    public func cleanUpLeftovers(tools: ToolEnvironment, secret: @Sendable (String, String) -> String?) async {
        guard session == nil,
              let data = try? Data(contentsOf: registryURL),
              let entry = try? JSONDecoder().decode(RegistryEntry.self, from: data) else { return }
        for group in entry.processGroups {
            await ProcessRunner.terminateOrphanedGroup(group, startedAt: entry.startedAt)
        }
        for file in entry.copiedFiles {
            try? FileManager.default.removeItem(atPath: file)
        }
        for (file, copy) in entry.savedFiles {
            Self.restore(URL(filePath: file), from: URL(filePath: copy))
        }
        try? FileManager.default.removeItem(at: stateDirectory.appending(path: "local-runs/\(entry.runID)/qa-login/private"))
        if let database = entry.database, let config = entry.databaseConfig {
            try? await Self.postgres(
                "dropdb", ["--force", "--if-exists", database], config: config,
                password: secret(entry.repositoryID, config.passwordSecret), tools: tools
            )
        }
        try? FileManager.default.removeItem(at: registryURL)
    }

    // MARK: - Steps

    private func setPhase(_ phase: LocalRunStatus.Phase) {
        session?.status.phase = phase
        report()
    }

    private func report() {
        if let status = session?.status { observer?(status) }
    }

    private func ensure(_ dependency: LocalRunConfig.Dependency, tools: ToolEnvironment, logDirectory: URL) async throws {
        if Self.isPortOpen(dependency.port) { return }
        guard !dependency.startCommand.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw LocalRunError.dependencyUnavailable(name: dependency.name, port: dependency.port, detail: "Start it, or add a start command.")
        }
        setPhase(.starting("Starting \(dependency.name)"))
        let result = try await ProcessRunner.run(ProcessRequest(
            executable: URL(filePath: "/bin/sh"), arguments: ["-c", dependency.startCommand],
            workingDirectory: URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory),
            environment: tools.variables(base: ClaudeCodeRunner.environment()), timeout: .seconds(300)
        ))
        try? (result.stdoutText + result.stderrText).write(
            to: logDirectory.appending(path: "dependency-\(Self.fileName(dependency.name)).log"), atomically: true, encoding: .utf8
        )
        for _ in 0..<90 where !Self.isPortOpen(dependency.port) {
            try await Task.sleep(for: .seconds(1))
        }
        guard Self.isPortOpen(dependency.port) else {
            let tail = (result.stderrText.isEmpty ? result.stdoutText : result.stderrText).suffix(300)
            throw LocalRunError.dependencyUnavailable(name: dependency.name, port: dependency.port, detail: "Start command: \(tail)")
        }
    }

    private func waitUntilReady(
        _ service: LocalRunConfig.Service, process: BackgroundProcess, port: Int?, environment: [String: String]
    ) async throws {
        func failure(_ detail: String) -> LocalRunError {
            let log = (try? String(contentsOf: process.logURL, encoding: .utf8)) ?? ""
            let hint = LocalRunDiagnosis.hint(forLog: log, environment: environment).map { "\n\n\($0)" } ?? ""
            return .serviceFailed(name: service.name, detail: "\(detail)\n\(process.logTail())\(hint)")
        }
        let deadline = ContinuousClock.now + .seconds(max(5, service.readyTimeoutSeconds))
        guard let port else {
            // No port (a worker): running if it has not exited after a few seconds.
            try await Task.sleep(for: .seconds(3))
            if let termination = process.termination {
                throw failure("exited (\(termination)).")
            }
            return
        }
        let path = service.readyPath.hasPrefix("/") ? service.readyPath : "/" + service.readyPath
        var lastStatus: Int?
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if let termination = process.termination {
                throw failure("exited (\(termination)) before it was ready.")
            }
            if let status = await Self.httpStatus(port: port, path: path) {
                if status < 500 { return }
                lastStatus = status
            }
            try await Task.sleep(for: .seconds(1))
        }
        let detail = lastStatus.map { "answered HTTP \($0) on \(path)" } ?? "did not answer on port \(port)"
        throw failure("\(detail) within \(service.readyTimeoutSeconds)s.")
    }

    private func saveRegistry(_ entry: RegistryEntry) throws {
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(entry).write(to: registryURL, options: .atomic)
    }

    // MARK: - Helpers

    static func databaseName(ticketID: String, runID: String) -> String {
        let ticket = ticketID.split(separator: "/").last.map(String.init) ?? ticketID
        return String("devpilot_\(GitWorktreeManager.slug(ticket, maxLength: 30).replacingOccurrences(of: "-", with: "_"))_\(runID)".prefix(63))
    }

    static func fileName(_ name: String) -> String {
        GitWorktreeManager.slug(name, maxLength: 40)
    }

    /// Runs `createdb`/`dropdb` from the build-tools PATH with the configured connection.
    static func postgres(
        _ tool: String, _ arguments: [String], config: LocalRunConfig.Database, password: String?, tools: ToolEnvironment
    ) async throws {
        let path = tools.variables(base: [:])["PATH"] ?? ToolEnvironment.systemPath
        guard let executable = path.split(separator: ":").map({ "\($0)/\(tool)" }).first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw LocalRunError.toolMissing(tool)
        }
        var environment = ClaudeCodeRunner.environment()
        environment["PGHOST"] = config.host
        environment["PGPORT"] = String(config.port)
        if !config.user.isEmpty { environment["PGUSER"] = config.user }
        if let password { environment["PGPASSWORD"] = password }
        let result = try await ProcessRunner.run(ProcessRequest(
            executable: URL(filePath: executable), arguments: arguments,
            workingDirectory: URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory),
            environment: environment, timeout: .seconds(120)
        ))
        guard result.succeeded else {
            throw LocalRunError.database(result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Loopback addresses a dev server may listen on: Node and Vite bind "localhost" to ::1 only.
    private static let loopbacks: [Int32] = [AF_INET, AF_INET6]

    /// A loopback socket address for `family` (AF_INET or AF_INET6), passed to `body`.
    private static func withLoopback<T>(_ family: Int32, port: Int, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        if family == AF_INET6 {
            var address = sockaddr_in6()
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_addr = in6addr_loopback
            address.sin6_port = in_port_t(UInt16(port).bigEndian)
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
    }

    /// Ports free on both 127.0.0.1 and ::1, held until all are chosen so they differ.
    static func freePorts(count: Int) throws -> [Int] {
        var sockets: [Int32] = []
        defer { sockets.forEach { close($0) } }
        func bound(_ family: Int32, port: Int) -> Int32? {
            let fd = socket(family, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            if withLoopback(family, port: port, { bind(fd, $0, $1) }) == 0 { return fd }
            close(fd)
            return nil
        }
        var ports: [Int] = []
        var attempts = 0
        while ports.count < count {
            attempts += 1
            guard attempts <= count * 20, let fd = bound(AF_INET, port: 0) else {
                throw LocalRunError.serviceFailed(name: "ports", detail: "no free local port")
            }
            sockets.append(fd)
            var address = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
            }
            let port = Int(UInt16(bigEndian: address.sin_port))
            // Taken on ::1 by another server: skip it (the IPv4 socket stays held so it is not offered again).
            guard let fd6 = bound(AF_INET6, port: port) else { continue }
            sockets.append(fd6)
            ports.append(port)
        }
        return ports
    }

    /// Whether something accepts connections on the port, on 127.0.0.1 or ::1.
    static func isPortOpen(_ port: Int) -> Bool {
        loopbacks.contains { family in
            let fd = socket(family, SOCK_STREAM, 0)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            var timeout = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            return withLoopback(family, port: port) { connect(fd, $0, $1) } == 0
        }
    }

    /// The HTTP status at `path` on the port, asking 127.0.0.1 and then ::1.
    static func httpStatus(port: Int, path: String) async -> Int? {
        for host in ["127.0.0.1", "[::1]"] {
            if let status = await httpStatus(URL(string: "http://\(host):\(port)\(path)")!) { return status }
        }
        return nil
    }

    static func httpStatus(_ url: URL) async -> Int? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        guard let (_, response) = try? await session.data(for: request) else { return nil }
        return (response as? HTTPURLResponse)?.statusCode
    }
}
