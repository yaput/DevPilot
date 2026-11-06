import Darwin
import Foundation
import Synchronization
import Testing
@testable import DevPilotCore

/// A main checkout (with an untracked .env), a worktree, and DevPilot's state folder.
struct LocalRunFixture {
    let root: URL
    let mainCheckout: URL
    let worktree: URL
    let state: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "devpilot-localrun-\(UUID().uuidString)", directoryHint: .isDirectory)
        mainCheckout = root.appending(path: "main", directoryHint: .isDirectory)
        worktree = root.appending(path: "worktree", directoryHint: .isDirectory)
        state = root.appending(path: "state", directoryHint: .isDirectory)
        for directory in [mainCheckout, worktree, state] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try "SECRET_FROM_ENV=1\n".write(to: mainCheckout.appending(path: ".env"), atomically: true, encoding: .utf8)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    static func httpService(_ name: String = "web", extra: String = "") -> LocalRunConfig.Service {
        LocalRunConfig.Service(
            name: name, portName: name,
            command: "\(extra)exec /usr/bin/python3 -m http.server {{port.\(name)}} --bind 127.0.0.1",
            readyTimeoutSeconds: 30
        )
    }

    func start(_ environment: LocalEnvironment, _ config: LocalRunConfig, secrets: [String: String] = [:]) async throws -> LocalRunStatus {
        try await environment.start(
            ticketID: "jira:acme/PLAT-1", repositoryID: "repo-1", worktree: worktree.path, mainCheckout: mainCheckout.path,
            config: config, secrets: secrets, tools: ToolEnvironment(path: "", javaHome: "")
        ) { _ in }
    }
}

struct LocalEnvironmentTests {
    @Test func startsServicesOnFreePortsAndCleansUpOnStop() async throws {
        let fixture = try LocalRunFixture()
        defer { fixture.remove() }
        var config = LocalRunConfig()
        config.services = [LocalRunFixture.httpService()]
        config.copyFiles = [".env"]
        config.appURL = "http://localhost:{{port.web}}/app"
        let environment = LocalEnvironment(stateDirectory: fixture.state)

        let status = try await fixture.start(environment, config)

        let port = try #require(status.services.first?.port)
        #expect(status.phase == .running)
        #expect(status.services.first?.state == .ready)
        #expect(status.appURL == "http://localhost:\(port)/app")
        #expect(LocalEnvironment.isPortOpen(port))
        #expect(FileManager.default.fileExists(atPath: fixture.worktree.appending(path: ".env").path), ".env copied for the run")
        #expect(FileManager.default.fileExists(atPath: fixture.state.appending(path: "local-run.json").path))

        await environment.stop()

        #expect(!LocalEnvironment.isPortOpen(port))
        #expect(!FileManager.default.fileExists(atPath: fixture.worktree.appending(path: ".env").path), ".env removed after")
        #expect(!FileManager.default.fileExists(atPath: fixture.state.appending(path: "local-run.json").path))
        #expect(await environment.status == nil)
    }

    @Test func placeholdersReachTheServiceEnvironment() async throws {
        let fixture = try LocalRunFixture()
        defer { fixture.remove() }
        var service = LocalRunFixture.httpService(extra: "printf '%s|%s|%s' \"$API_URL\" \"$TOKEN\" \"${CI:-unset}\" > env.txt; ")
        service.environment = [
            .init(key: "API_URL", value: "http://127.0.0.1:{{port.api}}"),
            .init(key: "TOKEN", value: "{{secret.token}}"),
        ]
        var config = LocalRunConfig()
        config.services = [service]
        let environment = LocalEnvironment(stateDirectory: fixture.state)

        _ = try await fixture.start(environment, config, secrets: ["token": "s3cret"])
        defer { Task { await environment.stop() } }

        let written = try String(contentsOf: fixture.worktree.appending(path: "env.txt"), encoding: .utf8)
        let parts = written.split(separator: "|").map(String.init)
        #expect(parts[0].hasPrefix("http://127.0.0.1:") && Int(parts[0].split(separator: ":").last!) != nil, "a port was allocated for {{port.api}}")
        #expect(parts[1] == "s3cret")
        #expect(parts[2] == "unset", "a local run is not a CI run")
        await environment.stop()
    }

    @Test func failingServiceReportsItsLogAndCleansUp() async throws {
        let fixture = try LocalRunFixture()
        defer { fixture.remove() }
        var config = LocalRunConfig()
        config.services = [LocalRunConfig.Service(name: "api", portName: "api", command: "echo 'Pending migration error'; exit 3", readyTimeoutSeconds: 10)]
        config.copyFiles = [".env"]
        let environment = LocalEnvironment(stateDirectory: fixture.state)

        await #expect {
            _ = try await fixture.start(environment, config)
        } throws: { error in
            guard case LocalRunError.serviceFailed(let name, let detail) = error else { return false }
            return name == "api" && detail.contains("Pending migration error")
        }
        #expect(await environment.status == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.worktree.appending(path: ".env").path))
        // Can start again after a failure.
        config.services = [LocalRunFixture.httpService()]
        _ = try await fixture.start(environment, config)
        await environment.stop()
    }

    @Test func serviceListeningOnlyOnIPv6LoopbackIsReady() async throws {
        let fixture = try LocalRunFixture()
        defer { fixture.remove() }
        var config = LocalRunConfig()
        // Like Vite, which binds "localhost" to ::1 only.
        config.services = [LocalRunConfig.Service(
            name: "web", portName: "web",
            command: "exec /usr/bin/python3 -m http.server {{port.web}} --bind ::1", readyTimeoutSeconds: 20
        )]
        let environment = LocalEnvironment(stateDirectory: fixture.state)
        let status = try await fixture.start(environment, config)
        let port = try #require(status.services.first?.port)
        #expect(status.services.first?.state == .ready)
        #expect(LocalEnvironment.isPortOpen(port))
        await environment.stop()
        #expect(!LocalEnvironment.isPortOpen(port))
    }

    @Test func freePortsAreFreeOnBothLoopbacks() throws {
        for port in try LocalEnvironment.freePorts(count: 5) {
            #expect(!LocalEnvironment.isPortOpen(port))
        }
    }

    @Test func oneRunAtATime() async throws {
        let fixture = try LocalRunFixture()
        defer { fixture.remove() }
        var config = LocalRunConfig()
        config.services = [LocalRunFixture.httpService()]
        let environment = LocalEnvironment(stateDirectory: fixture.state)
        _ = try await fixture.start(environment, config)
        await #expect(throws: LocalRunError.alreadyRunning("jira:acme/PLAT-1")) {
            _ = try await fixture.start(environment, config)
        }
        await environment.stop()
    }

    @Test func missingDependencyWithoutStartCommandFailsClearly() async throws {
        let fixture = try LocalRunFixture()
        defer { fixture.remove() }
        let closedPort = try LocalEnvironment.freePorts(count: 1)[0]
        var config = LocalRunConfig()
        config.dependencies = [.init(name: "db", port: closedPort, startCommand: "")]
        config.services = [LocalRunFixture.httpService()]
        let environment = LocalEnvironment(stateDirectory: fixture.state)

        await #expect(throws: LocalRunError.self) {
            _ = try await fixture.start(environment, config)
        }
        #expect(await environment.status == nil)
    }

    @Test func workersWithoutPortsRunUntilStopped() async throws {
        let fixture = try LocalRunFixture()
        defer { fixture.remove() }
        var config = LocalRunConfig()
        config.services = [
            LocalRunFixture.httpService(),
            .init(name: "worker", portName: "", command: "echo started > worker.txt; exec sleep 60"),
        ]
        let environment = LocalEnvironment(stateDirectory: fixture.state)
        let status = try await fixture.start(environment, config)
        #expect(status.services.map(\.state) == [.ready, .running])
        await environment.stop()
        #expect(FileManager.default.fileExists(atPath: fixture.worktree.appending(path: "worker.txt").path))
    }

    @Test func leftoversFromACrashAreCleanedUpNextLaunch() async throws {
        let fixture = try LocalRunFixture()
        defer { fixture.remove() }
        var config = LocalRunConfig()
        config.services = [LocalRunFixture.httpService()]
        config.copyFiles = [".env"]
        let crashed = LocalEnvironment(stateDirectory: fixture.state)
        let status = try await fixture.start(crashed, config)
        let port = try #require(status.services.first?.port)

        // A new app session finds the registry and cleans up.
        await LocalEnvironment(stateDirectory: fixture.state).cleanUpLeftovers(tools: ToolEnvironment(path: "", javaHome: "")) { _, _ in nil }

        for _ in 0..<50 where LocalEnvironment.isPortOpen(port) { try await Task.sleep(for: .milliseconds(100)) }
        #expect(!LocalEnvironment.isPortOpen(port))
        #expect(!FileManager.default.fileExists(atPath: fixture.worktree.appending(path: ".env").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.state.appending(path: "local-run.json").path))
    }

    @Test func databaseNamesAreSafeAndShort() {
        let name = LocalEnvironment.databaseName(ticketID: "shortcut:omakaseai-1/2476", runID: "ab12cd34")
        #expect(name == "devpilot_2476_ab12cd34")
        #expect(LocalEnvironment.databaseName(ticketID: "jira:x/" + String(repeating: "A-", count: 60), runID: "ab12cd34").count <= 63)
    }
}

struct LocalRunPresetTests {
    /// Shaped like omakase-v2: compose deps, Rails at the top level with a Procfile, Vite frontend.
    @Test func railsAndViteMonorepo() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "presets-local-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let files: [String: String] = [
            "docker-compose.yml": """
                services:
                  db:
                    image: pgvector/pgvector:pg16
                    environment:
                      POSTGRES_USER: app_dev
                      POSTGRES_PASSWORD: devpass
                      POSTGRES_DB: app_development
                    ports:
                      - "5432:5432"
                  redis:
                    image: redis:7
                    ports:
                      - "6379:6379"
                  localstack:
                    ports:
                      - "4566:4566"
                  mailhog:
                    ports:
                      - 8025:8025
                volumes:
                  pgdata:
                """,
            "Gemfile": "source 'https://rubygems.org'\n",
            "config/application.rb": "module App; end\n",
            "Procfile": "release: bundle exec rails db:migrate\nweb: bin/start-pgbouncer bundle exec rails server -p $PORT\nworker: IS_WORKER=true bin/start-pgbouncer bundle exec rails solid_queue:start\n",
            ".env": "X=1\n",
            "frontend/package.json": #"{"scripts": {"dev": "vite"}}"#,
            "frontend/pnpm-lock.yaml": "",
            "frontend/vite.config.ts": "const t = process.env.VITE_API_PROXY_TARGET || 'http://127.0.0.1:3000'",
            "frontend/.env": "VITE_X=1\n",
        ]
        for (path, contents) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }

        let (config, secrets) = LocalRunPresets.detect(repositoryAt: root.path)

        #expect(config.dependencies.map(\.name) == ["db", "redis", "localstack", "mailhog"])
        #expect(config.dependencies.map(\.isEnabled) == [true, true, true, false])
        #expect(config.dependencies.first?.startCommand.hasSuffix("compose -f docker-compose.yml up -d db") == true)
        #expect(config.database.isEnabled && config.database.user == "app_dev" && config.database.templateName == "app_development_devpilot_template")
        #expect(secrets == ["db_password": "devpass"])
        let api = try #require(config.services.first { $0.name == "api" })
        #expect(api.command.contains("rails server -p {{port.api}}"))
        #expect(api.environment.contains { $0.key == "DATABASE_URL" && $0.value.contains("{{database}}") && $0.value.contains("{{secret.db_password}}") })
        #expect(api.environment.contains { $0.key == "REDIS_URL" && $0.value == "redis://localhost:6379/5" })
        let worker = try #require(config.services.first { $0.name == "worker" })
        #expect(!worker.isEnabled)
        #expect(worker.command == "IS_WORKER=true bundle exec rails solid_queue:start")
        let web = try #require(config.services.first { $0.name == "web" })
        #expect(web.directory == "frontend")
        #expect(web.command == "pnpm run dev --port {{port.web}} --strictPort")
        #expect(web.environment.first { $0.key == "VITE_API_PROXY_TARGET" }?.value == "http://127.0.0.1:{{port.api}}")
        #expect(config.copyFiles == [".env", "frontend/.env"])
        #expect(config.appURL == "http://localhost:{{port.web}}")
    }

    @Test func placeholderResolution() {
        var values = PlaceholderValues()
        values.ports = ["api": 18082]
        values.database = "devpilot_x"
        values.databaseConfig.user = "u"
        values.secrets = ["db_password": "p"]
        #expect(values.resolve("postgres://{{db.user}}:{{secret.db_password}}@{{db.host}}:{{db.port}}/{{database}} api={{port.api}} {{port.unknown}}")
                == "postgres://u:p@localhost:5432/devpilot_x api=18082 {{port.unknown}}")
        #expect(PlaceholderValues.portNames(in: "a {{port.api}} b {{port.web}}") == ["api", "web"])
    }
}

struct OrphanIdentityTests {
    @Test(arguments: [("00:05", 5.0), ("12:34", 754.0), ("01:00:00", 3600.0), ("2-03:00:01", 183_601.0), ("  05:00 ", 300.0)])
    func parsesElapsed(text: String, seconds: Double) {
        #expect(ProcessRunner.parseElapsed(text) == seconds)
    }

    @Test func olderProcessesAreNeverKilled() async throws {
        let launched = Mutex<pid_t>(0)
        let task = Task {
            try await ProcessRunner.run(ProcessRequest(
                executable: URL(filePath: "/bin/sleep"), arguments: ["30"], workingDirectory: URL(filePath: "/"),
                environment: [:], timeout: .seconds(60), onLaunch: { pid in launched.withLock { $0 = pid } }
            ))
        }
        while launched.withLock({ $0 }) == 0 { try await Task.sleep(for: .milliseconds(20)) }
        let group = launched.withLock { $0 }

        // Recorded as started in the future: the running group is older, so it is not ours.
        #expect(await ProcessRunner.terminateOrphanedGroup(group, startedAt: Date().addingTimeInterval(60)) == false)
        #expect(kill(group, 0) == 0)
        #expect(await ProcessRunner.terminateOrphanedGroup(group, startedAt: Date().addingTimeInterval(-60)))
        _ = try? await task.value
    }
}

struct LocalRunSetupTests {
    @Test func setupRunsInTheWorktreeBeforeServices() async throws {
        let fixture = try LocalRunFixture()
        defer { fixture.remove() }
        var config = LocalRunConfig()
        config.services = [LocalRunFixture.httpService(extra: "test -f deps-installed && ")]
        let environment = LocalEnvironment(stateDirectory: fixture.state)
        _ = try await environment.start(
            ticketID: "t", repositoryID: "r", worktree: fixture.worktree.path, mainCheckout: fixture.mainCheckout.path,
            config: config, setupCommands: ["touch deps-installed"], secrets: [:], tools: ToolEnvironment(path: "", javaHome: "")
        ) { _ in }
        await environment.stop()
    }

    @Test func failingSetupStopsTheRun() async throws {
        let fixture = try LocalRunFixture()
        defer { fixture.remove() }
        var config = LocalRunConfig()
        config.services = [LocalRunFixture.httpService()]
        let environment = LocalEnvironment(stateDirectory: fixture.state)
        await #expect(throws: LocalRunError.self) {
            _ = try await environment.start(
                ticketID: "t", repositoryID: "r", worktree: fixture.worktree.path, mainCheckout: fixture.mainCheckout.path,
                config: config, setupCommands: ["echo 'lockfile out of date' >&2; exit 1"], secrets: [:], tools: ToolEnvironment(path: "", javaHome: "")
            ) { _ in }
        }
        #expect(await environment.status == nil)
    }

    @Test func optionalSetupFailureIsAWarning() async throws {
        let fixture = try LocalRunFixture()
        defer { fixture.remove() }
        var config = LocalRunConfig()
        config.services = [LocalRunFixture.httpService()]
        let environment = LocalEnvironment(stateDirectory: fixture.state)
        let failing = "cd tracker && exit 1"
        let status = try await environment.start(
            ticketID: "t", repositoryID: "r", worktree: fixture.worktree.path, mainCheckout: fixture.mainCheckout.path,
            config: config, setupCommands: [failing, "touch deps-installed"], optionalSetupCommands: [failing],
            secrets: [:], tools: ToolEnvironment(path: "", javaHome: "")
        ) { _ in }
        #expect(status.phase == .running)
        #expect(status.warnings.count == 1 && status.warnings[0].contains(failing))
        #expect(FileManager.default.fileExists(atPath: fixture.worktree.appending(path: "deps-installed").path))
        await environment.stop()
    }
}

struct RubyPresetTests {
    @Test func railsProjectWithRSpec() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "presets-ruby-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["Gemfile", "bin/rails", ".rspec"] {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        let presets = CommandPresets.detect(repositoryAt: root.path)
        #expect(presets.setup.map(\.command) == ["bundle install"])
        #expect(presets.validation.map(\.command) == [CommandPresets.changedSpecsCommand])
        #expect(presets.agent.map(\.command).prefix(3) == ["bundle", "ruby", "bin/rails"])
    }
}

struct ProjectDirectoryTests {
    func tree(_ files: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "projects-\(UUID().uuidString)", directoryHint: .isDirectory)
        for path in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        return root
    }

    @Test func railsWithNodeFrontendFindsBoth() throws {
        let root = try tree(["Gemfile", "frontend/package.json"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(CommandPresets.projectDirectories(in: root) == ["", "frontend"])
    }

    @Test func gradleModulesAreNotSeparateProjects() throws {
        let root = try tree(["build.gradle", "gradlew", "app/build.gradle", "lib/build.gradle"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(CommandPresets.projectDirectories(in: root) == [""])
    }

    @Test func nodeWorkspacePackagesAreNotSeparateProjects() throws {
        let root = try tree(["package.json", "packages/ui/package.json"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(CommandPresets.projectDirectories(in: root) == [""])
    }

    @Test func servicesFolderWithoutTopLevelProject() throws {
        let root = try tree(["services/core/gradlew", "services/core/build.gradle", "services/ui/package.json", "README.md"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(CommandPresets.projectDirectories(in: root) == ["services/core", "services/ui"])
    }
}

struct EndToEndSuitePresetTests {
    @Test func browserSuitesAreSuggestedButUnchecked() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "presets-e2e-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        for (path, contents) in ["Gemfile": "", ".rspec": "", "e2e/package.json": #"{"scripts": {"test": "playwright test"}}"#] {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        let validation = CommandPresets.detect(repositoryAt: root.path).validation
        #expect(validation.map(\.command) == [CommandPresets.changedSpecsCommand, "cd e2e && npm run test"])
        #expect(validation.map(\.isEnabled) == [true, false])
    }
}

struct LocalRunCancellationTests {
    @Test func cancellingWhileStartingCleansUp() async throws {
        let fixture = try LocalRunFixture()
        defer { fixture.remove() }
        var config = LocalRunConfig()
        // Never becomes ready: listens on nothing.
        config.services = [LocalRunConfig.Service(name: "web", portName: "web", command: "exec sleep 60", readyTimeoutSeconds: 60)]
        config.copyFiles = [".env"]
        let environment = LocalEnvironment(stateDirectory: fixture.state)
        let start = Task { try await fixture.start(environment, config) }
        try await Task.sleep(for: .seconds(1))

        start.cancel()
        await #expect(throws: (any Error).self) { _ = try await start.value }

        #expect(await environment.status == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.worktree.appending(path: ".env").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.state.appending(path: "local-run.json").path))
    }
}

struct LocalRunDiagnosisTests {
    @Test func expiredAWSSignInNamesTheProfile() {
        let log = """
            /gems/aws-sdk-core/sso_token_provider.rb:72:in 'refresh': Token is invalid and failed to refresh (Aws::Errors::InvalidSSOToken)
            \tfrom config/application.rb:124:in 'initialize_envs_using_secret'
            """
        #expect(LocalRunDiagnosis.hint(forLog: log, environment: ["AWS_PROFILE": "omakase-dev"])
            == "The AWS SSO sign-in has expired. Run `aws sso login --profile omakase-dev`, then start again.")
        #expect(LocalRunDiagnosis.hint(forLog: log)?.contains("`aws sso login`") == true)
    }

    @Test func missingRubyAndNodeVersions() {
        #expect(LocalRunDiagnosis.hint(forLog: "rbenv: version `3.4.11' is not installed (set by /w/.ruby-version)")?
            .contains("rbenv install 3.4.11") == true)
        #expect(LocalRunDiagnosis.hint(forLog: "Your Ruby version is 3.4.9, but your Gemfile specified 3.4.11")?
            .contains("rbenv install 3.4.11") == true)
        #expect(LocalRunDiagnosis.hint(forLog: "N/A: version \"v22.1.0\" is not yet installed.")?
            .contains("nvm install v22.1.0") == true)
    }

    @Test func unknownFailuresHaveNoHint() {
        #expect(LocalRunDiagnosis.hint(forLog: "NoMethodError: undefined method 'foo' for nil") == nil)
    }

    @Test func dotenvParsing() throws {
        let fixture = try LocalRunFixture()
        defer { fixture.remove() }
        let url = fixture.root.appending(path: "sample.env")
        try "# comment\nexport AWS_PROFILE=\"dev\"\nEMPTY=\nURL=postgres://a=b\n".write(to: url, atomically: true, encoding: .utf8)
        #expect(LocalRunDiagnosis.dotenv(at: url) == ["AWS_PROFILE": "dev", "EMPTY": "", "URL": "postgres://a=b"])
    }

    @Test func failingServiceGetsAHintFromItsWholeLogAndDotenv() async throws {
        let fixture = try LocalRunFixture()
        defer { fixture.remove() }
        try "AWS_PROFILE=team-dev\n".write(to: fixture.mainCheckout.appending(path: ".env"), atomically: true, encoding: .utf8)
        var config = LocalRunConfig()
        // The cause is followed by a long backtrace, so it is outside the log tail.
        config.services = [LocalRunConfig.Service(
            name: "api", portName: "api",
            command: "echo 'failed (Aws::Errors::InvalidSSOToken)'; seq 1 100; exit 1", readyTimeoutSeconds: 10
        )]
        config.copyFiles = [".env"]
        await #expect {
            _ = try await fixture.start(LocalEnvironment(stateDirectory: fixture.state), config)
        } throws: { error in
            guard case LocalRunError.serviceFailed(_, let detail) = error else { return false }
            return detail.hasSuffix("Run `aws sso login --profile team-dev`, then start again.")
        }
    }
}

struct LocalhostOverrideTests {
    @Test func envURLsOnUsualPortsPointAtTheRunsPorts() throws {
        let fixture = try LocalRunFixture()
        defer { fixture.remove() }
        let root = fixture.mainCheckout
        try FileManager.default.createDirectory(at: root.appending(path: "frontend"), withIntermediateDirectories: true)
        try """
            VITE_API_BASE_URL=http://localhost:3000
            VITE_WIDGET_CDN_URL="http://localhost:5173/widget"
            VITE_SHOPIFY_APP_URL=http://localhost:65150
            VITE_DB=postgres://u:p@localhost:3000/x
            VITE_ALREADY_SET=http://localhost:3000
            """.write(to: root.appending(path: "frontend/.env"), atomically: true, encoding: .utf8)
        try "APP_URL=http://127.0.0.1:5173\n".write(to: root.appending(path: ".env"), atomically: true, encoding: .utf8)
        var config = LocalRunConfig()
        config.services = [
            .init(name: "api", portName: "api", command: "bundle exec rails server -p {{port.api}}"),
            .init(name: "web", portName: "web", directory: "frontend", command: "pnpm run dev --port {{port.web}}",
                  environment: [.init(key: "VITE_ALREADY_SET", value: "kept")]),
        ]
        config.copyFiles = [".env", "frontend/.env"]
        #expect(LocalRunPresets.addLocalhostOverrides(to: &config, repositoryAt: root.path))
        let web = Dictionary(uniqueKeysWithValues: config.services[1].environment.map { ($0.key, $0.value) })
        #expect(web == [
            "VITE_ALREADY_SET": "kept",
            "VITE_API_BASE_URL": "http://localhost:{{port.api}}",
            "VITE_WIDGET_CDN_URL": "http://localhost:{{port.web}}/widget",
        ])
        #expect(config.services[0].environment.map(\.key) == ["APP_URL"])
        #expect(config.services[0].environment.first?.value == "http://127.0.0.1:{{port.web}}")
        // Running it again adds nothing.
        #expect(!LocalRunPresets.addLocalhostOverrides(to: &config, repositoryAt: root.path))
    }

    @Test func frontEndWithAProxyKeepsAPICallsSameOrigin() throws {
        let fixture = try LocalRunFixture()
        defer { fixture.remove() }
        let root = fixture.mainCheckout
        try FileManager.default.createDirectory(at: root.appending(path: "frontend"), withIntermediateDirectories: true)
        try "VITE_API_BASE_URL=http://localhost:3000\nVITE_CABLE_URL=ws://localhost:3000/cable\nVITE_ADMIN=http://localhost:3000/admin/x\n"
            .write(to: root.appending(path: "frontend/.env"), atomically: true, encoding: .utf8)
        try "server: { proxy: { '/api': { target }, \"/admin\": { target } } }"
            .write(to: root.appending(path: "frontend/vite.config.ts"), atomically: true, encoding: .utf8)
        var config = LocalRunConfig()
        config.services = [
            .init(name: "api", portName: "api", command: "bundle exec rails server -p {{port.api}}"),
            .init(name: "web", portName: "web", directory: "frontend", command: "pnpm run dev --port {{port.web}}"),
        ]
        config.copyFiles = ["frontend/.env"]
        LocalRunPresets.addLocalhostOverrides(to: &config, repositoryAt: root.path)
        let web = Dictionary(uniqueKeysWithValues: config.services[1].environment.map { ($0.key, $0.value) })
        #expect(web == [
            "VITE_API_BASE_URL": "http://localhost:{{port.web}}",
            "VITE_ADMIN": "http://localhost:{{port.web}}/admin/x",
            "VITE_CABLE_URL": "ws://localhost:{{port.api}}/cable",
        ])
    }
}

struct RestoreFilesTests {
    @Test func filesTheRunRewritesArePutBack() async throws {
        let fixture = try LocalRunFixture()
        defer { fixture.remove() }
        let schema = fixture.worktree.appending(path: "db/structure.sql")
        try FileManager.default.createDirectory(at: schema.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "-- committed\n".write(to: schema, atomically: true, encoding: .utf8)
        var config = LocalRunConfig()
        config.restoreFiles = ["db/structure.sql", "db/missing.sql"]
        config.services = [LocalRunFixture.httpService(extra: "echo '-- dumped again' > db/structure.sql; ")]
        let environment = LocalEnvironment(stateDirectory: fixture.state)
        _ = try await fixture.start(environment, config)
        #expect(try String(contentsOf: schema, encoding: .utf8) == "-- dumped again\n")
        await environment.stop()
        #expect(try String(contentsOf: schema, encoding: .utf8) == "-- committed\n")
        #expect(!FileManager.default.fileExists(atPath: fixture.worktree.appending(path: "db/missing.sql").path))
    }
}
