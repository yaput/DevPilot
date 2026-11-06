import Foundation
import Testing
@testable import DevPilotCore

/// Creates and drops a real throwaway test database. Opt-in because it needs a local Postgres
/// and a role that may create roles (usually the one the local run uses):
///
///     DEVPILOT_LIVE_PG_USER=postgres DEVPILOT_LIVE_PG_PASSWORD=… swift test --filter LiveValidationDatabaseTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DEVPILOT_LIVE_PG_USER"] != nil))
struct LiveValidationDatabaseTests {
    let environment = ProcessInfo.processInfo.environment
    var tools: ToolEnvironment { ToolEnvironment(path: environment["PATH"] ?? "", javaHome: "") }

    var config: LocalRunConfig.Database {
        var config = LocalRunConfig.Database()
        config.isEnabled = true
        config.user = environment["DEVPILOT_LIVE_PG_USER"] ?? ""
        config.port = Int(environment["DEVPILOT_LIVE_PG_PORT"] ?? "") ?? 5432
        return config
    }

    /// Runs psql as the throwaway role, the way the sandboxed tests connect.
    func psqlAsTestRole(_ database: ValidationDatabase, _ sql: String, in name: String? = nil) async throws -> ProcessResult {
        var variables = ClaudeCodeRunner.environment().merging(database.environment) { _, new in new }
        if let name { variables["PGDATABASE"] = name }
        return try await ProcessRunner.run(ProcessRequest(
            executable: URL(filePath: "/usr/bin/env"), arguments: ["psql", "-X", "-At", "-v", "ON_ERROR_STOP=1", "-c", sql],
            workingDirectory: URL(filePath: NSHomeDirectory()), environment: variables.merging(["PATH": environment["PATH"] ?? ""]) { _, new in new },
            timeout: .seconds(30)
        ))
    }

    @Test func throwawayRoleCanRebuildItsDatabaseButNotTouchOthers() async throws {
        let admin = environment["DEVPILOT_LIVE_PG_PASSWORD"]
        let database = try await ValidationDatabase.create(ticketID: "live/SC-1", config: config, adminPassword: admin, tools: tools)

        // What Rails' db:test:prepare and structure.sql do: trusted extensions, comments, drop and recreate.
        let schema = try await psqlAsTestRole(database, "CREATE EXTENSION IF NOT EXISTS pgcrypto; COMMENT ON EXTENSION pgcrypto IS 'x'; SELECT current_user")
        #expect(schema.succeeded, "\(schema.stderrText)")
        #expect(schema.stdoutText.contains(database.name))
        let recreate = try await psqlAsTestRole(database, "DROP DATABASE \"\(database.name)\"", in: "postgres")
        #expect(recreate.succeeded, "\(recreate.stderrText)")
        let create = try await psqlAsTestRole(database, "CREATE DATABASE \"\(database.name)\"", in: "postgres")
        #expect(create.succeeded, "\(create.stderrText)")
        let superuser = try await psqlAsTestRole(database, "SELECT rolsuper FROM pg_roles WHERE rolname = current_user")
        #expect(superuser.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines) == "f")

        await database.drop(adminPassword: admin, tools: tools)
        let left = try await LocalEnvironment.postgres(
            "psql", ["-X", "-At", "-d", "postgres", "-c", "SELECT count(*) FROM pg_roles WHERE rolname = '\(database.name)'"],
            config: config, password: admin, tools: tools
        )
        #expect(left.trimmingCharacters(in: .whitespacesAndNewlines) == "0")
    }
}
