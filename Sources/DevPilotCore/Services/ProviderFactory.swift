import Foundation

/// Builds the active ticket providers from settings and stored credentials.
public struct ProviderFactory: Sendable {
    private let credentials: any CredentialStore
    private let http: any HTTPClient

    public init(credentials: any CredentialStore, http: any HTTPClient) {
        self.credentials = credentials
        self.http = http
    }

    /// Enabled providers only. A provider that is enabled but incomplete becomes an
    /// `UnconfiguredTicketProvider`, so the problem is visible in sync status.
    public func makeProviders(_ settings: ProviderSettings) -> [any TicketProvider] {
        if settings.useSampleData {
            return TicketProviderKind.allCases.map { MockTicketProvider.sample($0) }
        }
        var providers: [any TicketProvider] = []
        if settings.shortcut.isEnabled {
            providers.append(makeProvider(.shortcut, settings: settings, token: nil))
        }
        if settings.jira.isEnabled {
            providers.append(makeProvider(.jira, settings: settings, token: nil))
        }
        return providers
    }

    /// Builds one live provider. `token` overrides the stored token (used to test unsaved settings).
    public func makeProvider(_ kind: TicketProviderKind, settings: ProviderSettings, token: String?) -> any TicketProvider {
        do {
            switch kind {
            case .shortcut:
                let apiURL = try ProviderURL.normalize(settings.shortcut.apiURL, field: "Shortcut API URL")
                let token = try resolveToken(token, account: .shortcutToken, name: "Shortcut API token")
                return ShortcutTicketProvider(apiURL: apiURL, apiToken: token, http: http)
            case .jira:
                let siteURL = try ProviderURL.normalize(settings.jira.siteURL, field: "Jira site URL")
                let email = settings.jira.email.trimmingCharacters(in: .whitespaces)
                guard !email.isEmpty else { throw SettingsError.missing("Jira account email") }
                let token = try resolveToken(token, account: .jiraToken, name: "Jira API token")
                return JiraTicketProvider(
                    siteURL: siteURL, email: email, apiToken: token,
                    acceptanceCriteriaField: try settings.jira.validatedFieldID(), http: http
                )
            }
        } catch {
            return UnconfiguredTicketProvider(kind: kind, reason: error.localizedDescription)
        }
    }

    private func resolveToken(_ override: String?, account: CredentialAccount, name: String) throws -> String {
        let token = (override?.isEmpty == false ? override : try credentials.secret(for: account)) ?? ""
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SettingsError.missing(name) }
        return trimmed
    }
}
