import Foundation

/// Non-secret provider configuration, editable in Settings. Tokens live in `CredentialStore`.
public struct ProviderSettings: Codable, Sendable, Equatable {
    public var useSampleData = false
    public var shortcut = ShortcutSettings()
    public var jira = JiraSettings()

    public init() {}
}

public struct ShortcutSettings: Codable, Sendable, Equatable {
    public static let defaultAPIURL = "https://api.app.shortcut.com"

    public var isEnabled = false
    /// The workspace is determined by the API token; this only changes for proxies or testing.
    public var apiURL = Self.defaultAPIURL

    public init() {}
}

public struct JiraSettings: Codable, Sendable, Equatable {
    public var isEnabled = false
    /// e.g. `https://your-company.atlassian.net`
    public var siteURL = ""
    public var email = ""
    /// Optional custom field holding acceptance criteria, e.g. `customfield_10035`.
    public var acceptanceCriteriaField = ""

    public init() {}
}

// Missing keys fall back to defaults, so adding a setting later never discards saved ones.
extension ProviderSettings {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        useSampleData = try container.decodeIfPresent(Bool.self, forKey: .useSampleData) ?? useSampleData
        shortcut = try container.decodeIfPresent(ShortcutSettings.self, forKey: .shortcut) ?? shortcut
        jira = try container.decodeIfPresent(JiraSettings.self, forKey: .jira) ?? jira
    }
}

extension ShortcutSettings {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? isEnabled
        apiURL = try container.decodeIfPresent(String.self, forKey: .apiURL) ?? apiURL
    }
}

extension JiraSettings {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? isEnabled
        siteURL = try container.decodeIfPresent(String.self, forKey: .siteURL) ?? siteURL
        email = try container.decodeIfPresent(String.self, forKey: .email) ?? email
        acceptanceCriteriaField = try container.decodeIfPresent(String.self, forKey: .acceptanceCriteriaField) ?? acceptanceCriteriaField
    }
}

public enum SettingsError: Error, Equatable, LocalizedError {
    case missing(String)
    case invalidURL(String)
    case insecureURL(String)
    case invalidField(String)

    public var errorDescription: String? {
        switch self {
        case .missing(let field): "\(field) is required."
        case .invalidURL(let value): "'\(value)' is not a valid URL."
        case .insecureURL(let value): "'\(value)' must use https."
        case .invalidField(let value): "'\(value)' is not a Jira field ID (expected e.g. customfield_10035)."
        }
    }
}

public enum ProviderURL {
    /// Accepts `acme.atlassian.net`, `https://acme.atlassian.net/jira/your-work` etc. and returns
    /// `https://acme.atlassian.net`. Only https is allowed: the token is sent with every request.
    public static func normalize(_ input: String, field: String) throws -> URL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SettingsError.missing(field) }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let components = URLComponents(string: withScheme),
              let host = components.host, !host.isEmpty, !host.contains(" ") else {
            throw SettingsError.invalidURL(trimmed)
        }
        guard components.scheme?.lowercased() == "https" else { throw SettingsError.insecureURL(trimmed) }
        var normalized = URLComponents()
        normalized.scheme = "https"
        normalized.host = host.lowercased()
        normalized.port = components.port
        guard let url = normalized.url else { throw SettingsError.invalidURL(trimmed) }
        return url
    }
}

extension JiraSettings {
    public func validatedFieldID() throws -> String? {
        let field = acceptanceCriteriaField.trimmingCharacters(in: .whitespaces)
        guard !field.isEmpty else { return nil }
        guard field.wholeMatch(of: /customfield_\d+/) != nil else { throw SettingsError.invalidField(field) }
        return field
    }
}

/// A settings group stored as JSON under its own UserDefaults key.
public protocol StoredSettings: Codable, Equatable, Sendable {
    static var storageKey: String { get }
    init()
}

extension ProviderSettings: StoredSettings {
    public static let storageKey = "providerSettings"
}

/// Persists settings groups as JSON in UserDefaults. Unreadable data falls back to defaults.
public struct SettingsStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load<T: StoredSettings>(_ type: T.Type = T.self) -> T {
        guard let data = defaults.data(forKey: T.storageKey),
              let settings = try? JSONDecoder().decode(T.self, from: data) else {
            return T()
        }
        return settings
    }

    public func save<T: StoredSettings>(_ settings: T) throws {
        defaults.set(try JSONEncoder().encode(settings), forKey: T.storageKey)
    }
}
