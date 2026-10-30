import Foundation
import Testing
@testable import DevPilotCore

struct ProviderURLTests {
    @Test(arguments: [
        ("acme.atlassian.net", "https://acme.atlassian.net"),
        ("https://acme.atlassian.net/", "https://acme.atlassian.net"),
        ("  https://ACME.atlassian.net/jira/your-work?x=1 ", "https://acme.atlassian.net"),
        ("https://api.app.shortcut.com", "https://api.app.shortcut.com"),
        ("https://jira.internal.example:8443/", "https://jira.internal.example:8443"),
    ])
    func normalizes(input: String, expected: String) throws {
        #expect(try ProviderURL.normalize(input, field: "URL").absoluteString == expected)
    }

    @Test func rejectsHTTP() {
        #expect(throws: SettingsError.insecureURL("http://acme.atlassian.net")) {
            try ProviderURL.normalize("http://acme.atlassian.net", field: "URL")
        }
    }

    @Test func rejectsEmptyAndGarbage() {
        #expect(throws: SettingsError.missing("Jira site URL")) { try ProviderURL.normalize("  ", field: "Jira site URL") }
        #expect(throws: SettingsError.self) { try ProviderURL.normalize("https://", field: "URL") }
    }

    @Test func validatesCriteriaFieldID() throws {
        var jira = JiraSettings()
        #expect(try jira.validatedFieldID() == nil)
        jira.acceptanceCriteriaField = " customfield_10035 "
        #expect(try jira.validatedFieldID() == "customfield_10035")
        jira.acceptanceCriteriaField = "Acceptance Criteria"
        #expect(throws: SettingsError.invalidField("Acceptance Criteria")) { try jira.validatedFieldID() }
    }
}

struct SettingsStoreTests {
    @Test func roundTripsAndDefaults() throws {
        let defaults = UserDefaults(suiteName: "devpilot-tests-\(UUID().uuidString)")!
        let store = SettingsStore(defaults: defaults)
        #expect(store.load(ProviderSettings.self) == ProviderSettings())

        var settings = ProviderSettings()
        settings.jira.isEnabled = true
        settings.jira.siteURL = "https://acme.atlassian.net"
        try store.save(settings)
        #expect(store.load(ProviderSettings.self) == settings)
    }
}

struct SettingsDecodingTests {
    @Test func missingKeysKeepDefaultsAndSavedValues() throws {
        let json = #"{"jira": {"isEnabled": true, "siteURL": "https://acme.atlassian.net"}}"#
        let settings = try JSONDecoder().decode(ProviderSettings.self, from: Data(json.utf8))
        #expect(settings.jira.siteURL == "https://acme.atlassian.net")
        #expect(settings.jira.isEnabled)
        #expect(settings.jira.email == "")
        #expect(settings.shortcut.apiURL == ShortcutSettings.defaultAPIURL)
        #expect(!settings.useSampleData)
    }
}

struct ProviderFactoryTests {
    let http = MockHTTPClient { _ in .status(500) }

    @Test func sampleDataUsesMocksForBothProviders() {
        var settings = ProviderSettings()
        settings.useSampleData = true
        let providers = ProviderFactory(credentials: InMemoryCredentialStore(), http: http).makeProviders(settings)
        #expect(providers.map(\.kind) == [.shortcut, .jira])
        #expect(providers.allSatisfy { $0 is MockTicketProvider })
    }

    @Test func disabledProvidersAreOmitted() {
        let providers = ProviderFactory(credentials: InMemoryCredentialStore(), http: http).makeProviders(ProviderSettings())
        #expect(providers.isEmpty)
    }

    @Test func enabledButIncompleteProviderExplainsWhy() async {
        var settings = ProviderSettings()
        settings.jira.isEnabled = true
        settings.jira.siteURL = "acme.atlassian.net"
        settings.jira.email = "jane@example.com"
        let providers = ProviderFactory(credentials: InMemoryCredentialStore(), http: http).makeProviders(settings)

        let provider = providers.first as? UnconfiguredTicketProvider
        #expect(provider?.reason == "Jira API token is required.")
    }

    @Test func configuredProvidersAreLive() {
        var settings = ProviderSettings()
        settings.shortcut.isEnabled = true
        settings.jira.isEnabled = true
        settings.jira.siteURL = "acme.atlassian.net"
        settings.jira.email = "jane@example.com"
        let credentials = InMemoryCredentialStore([.shortcutToken: "a", .jiraToken: "b"])

        let providers = ProviderFactory(credentials: credentials, http: http).makeProviders(settings)

        #expect(providers[0] is ShortcutTicketProvider)
        #expect(providers[1] is JiraTicketProvider)
    }

    @Test func explicitTokenOverridesStoredOne() {
        var settings = ProviderSettings()
        settings.shortcut.isEnabled = true
        let provider = ProviderFactory(credentials: InMemoryCredentialStore(), http: http)
            .makeProvider(.shortcut, settings: settings, token: "typed-but-unsaved")
        #expect(provider is ShortcutTicketProvider)
    }
}
