import Foundation

public enum ValidationDatabaseError: Error, Equatable, LocalizedError {
    case notConfigured
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Tests need a database, but this repository has no database connection with a saved password. Set it up in Settings → Repositories → Local Run."
        case .failed(let detail): "Could not create the test database: \(detail)"
        }
    }
}

/// A throwaway Postgres database for one validation run, owned by a throwaway role with a random
/// password. DevPilot creates both through the local run's connection (usually a superuser) and
/// drops them afterwards; the sandboxed tests only ever see the throwaway role. It may create
/// databases (Rails' `db:test:prepare` drops and recreates its test database) but is no superuser,
/// so it cannot touch the development database.
public struct ValidationDatabase: Sendable, Equatable {
    /// Role and database names start with it, so leftovers from a crash can be found.
    static let prefix = "devpilot_vt_"

    public let name: String
    let password: String
    let config: LocalRunConfig.Database

    /// For the validation commands: `DATABASE_URL` (Rails, Prisma, …) plus libpq's `PG*`.
    public var environment: [String: String] {
        [
            "DATABASE_URL": "postgres://\(name):\(password)@\(config.host):\(config.port)/\(name)",
            "PGHOST": config.host,
            "PGPORT": String(config.port),
            "PGUSER": name,
            "PGPASSWORD": password,
            "PGDATABASE": name,
        ]
    }

    static func name(ticketID: String) -> String {
        let ticket = ticketID.split(separator: "/").last.map(String.init) ?? ticketID
        let slug = GitWorktreeManager.slug(ticket, maxLength: 30).replacingOccurrences(of: "-", with: "_")
        let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))
        return "\(prefix)\(slug)_\(suffix)"
    }

    public static func create(
        ticketID: String, config: LocalRunConfig.Database, adminPassword: String?, tools: ToolEnvironment
    ) async throws -> ValidationDatabase {
        guard config.isEnabled, !config.user.isEmpty, let adminPassword, !adminPassword.isEmpty else {
            throw ValidationDatabaseError.notConfigured
        }
        let database = ValidationDatabase(
            name: name(ticketID: ticketID),
            password: UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            config: config
        )
        do {
            // Names and password are [a-z0-9_] only, so quoting them is enough.
            try await psql("CREATE ROLE \"\(database.name)\" LOGIN CREATEDB PASSWORD '\(database.password)'", config: config, password: adminPassword, tools: tools)
            try await LocalEnvironment.postgres("createdb", ["-O", database.name, database.name], config: config, password: adminPassword, tools: tools)
        } catch {
            await database.drop(adminPassword: adminPassword, tools: tools)
            throw ValidationDatabaseError.failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        return database
    }

    /// Drops every database the role owns (the tests may have recreated or added some), then the role.
    public func drop(adminPassword: String?, tools: ToolEnvironment) async {
        await Self.drop(role: name, config: config, adminPassword: adminPassword, tools: tools)
    }

    /// After a crash: drops throwaway roles and their databases that are still there. Only call
    /// it when no validation of this app is running.
    public static func cleanUpLeftovers(config: LocalRunConfig.Database, adminPassword: String?, tools: ToolEnvironment) async {
        guard config.isEnabled, !config.user.isEmpty, adminPassword != nil else { return }
        let roles = (try? await psql(
            "SELECT rolname FROM pg_roles WHERE starts_with(rolname, '\(prefix)')", config: config, password: adminPassword, tools: tools
        )) ?? ""
        for role in roles.split(whereSeparator: \.isNewline) {
            await drop(role: String(role), config: config, adminPassword: adminPassword, tools: tools)
        }
    }

    private static func drop(role: String, config: LocalRunConfig.Database, adminPassword: String?, tools: ToolEnvironment) async {
        let owned = (try? await psql(
            "SELECT datname FROM pg_database WHERE datdba = (SELECT oid FROM pg_roles WHERE rolname = '\(role)')",
            config: config, password: adminPassword, tools: tools
        )) ?? ""
        for database in Set(owned.split(whereSeparator: \.isNewline).map(String.init) + [role]) {
            try? await LocalEnvironment.postgres("dropdb", ["--force", "--if-exists", database], config: config, password: adminPassword, tools: tools)
        }
        try? await psql("DROP ROLE IF EXISTS \"\(role)\"", config: config, password: adminPassword, tools: tools)
    }

    @discardableResult
    private static func psql(_ sql: String, config: LocalRunConfig.Database, password: String?, tools: ToolEnvironment) async throws -> String {
        try await LocalEnvironment.postgres(
            "psql", ["-X", "-At", "-v", "ON_ERROR_STOP=1", "-d", "postgres", "-c", sql], config: config, password: password, tools: tools
        )
    }
}
