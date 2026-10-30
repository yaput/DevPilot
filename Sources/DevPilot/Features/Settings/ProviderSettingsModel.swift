import DevPilotCore
import Foundation
import Observation

/// Draft state for the Providers settings tab. Nothing is persisted until `save()`.
@MainActor
@Observable
final class ProviderSettingsModel {
    enum ConnectionStatus: Equatable {
        case idle
        case checking
        case connected(String)
        case failed(String)
    }

    private let app: AppModel
    private let store: SettingsStore
    private let credentials: any CredentialStore
    private let factory: ProviderFactory

    var draft: ProviderSettings
    /// Newly typed tokens. Empty means "keep the stored token".
    var shortcutToken = ""
    var jiraToken = ""
    private(set) var storedTokens: Set<CredentialAccount> = []
    private(set) var status: [TicketProviderKind: ConnectionStatus] = [:]
    private(set) var error: String?
    private(set) var isSaving = false

    init(app: AppModel, store: SettingsStore, credentials: any CredentialStore, factory: ProviderFactory) {
        self.app = app
        self.store = store
        self.credentials = credentials
        self.factory = factory
        self.draft = store.load()
    }

    var hasChanges: Bool {
        draft != store.load() || !shortcutToken.isEmpty || !jiraToken.isEmpty
    }

    /// Discards unsaved edits; called whenever the Settings window opens.
    func reset() {
        draft = store.load()
        shortcutToken = ""
        jiraToken = ""
        status = [:]
        error = nil
        refreshStoredTokens()
    }

    func save() async {
        error = nil
        do {
            try normalizeDraft()
            for (account, typed) in [(CredentialAccount.shortcutToken, shortcutToken), (.jiraToken, jiraToken)] {
                let token = typed.trimmingCharacters(in: .whitespacesAndNewlines)
                if !token.isEmpty { try credentials.setSecret(token, for: account) }
            }
            try store.save(draft)
        } catch {
            self.error = error.localizedDescription
            return
        }
        shortcutToken = ""
        jiraToken = ""
        refreshStoredTokens()
        isSaving = true
        await app.reconfigure()
        isSaving = false
    }

    /// Tests the draft values, including a typed-but-unsaved token.
    func testConnection(_ kind: TicketProviderKind) async {
        status[kind] = .checking
        let typed = kind == .shortcut ? shortcutToken : jiraToken
        let provider = factory.makeProvider(kind, settings: draft, token: typed.trimmingCharacters(in: .whitespacesAndNewlines))
        do {
            status[kind] = .connected(try await provider.checkConnection())
        } catch {
            status[kind] = .failed(error.localizedDescription)
        }
    }

    func removeToken(_ kind: TicketProviderKind) async {
        do {
            try credentials.deleteSecret(for: kind.credentialAccount)
        } catch {
            self.error = error.localizedDescription
            return
        }
        status[kind] = nil
        refreshStoredTokens()
        await app.reconfigure()
    }

    func hasStoredToken(_ kind: TicketProviderKind) -> Bool {
        storedTokens.contains(kind.credentialAccount)
    }

    /// Validates enabled providers and rewrites URLs to their canonical form.
    private func normalizeDraft() throws {
        guard !draft.useSampleData else { return }
        if draft.shortcut.isEnabled {
            draft.shortcut.apiURL = try ProviderURL.normalize(draft.shortcut.apiURL, field: "Shortcut API URL").absoluteString
            try requireToken(typed: shortcutToken, kind: .shortcut, name: "Shortcut API token")
        }
        if draft.jira.isEnabled {
            draft.jira.siteURL = try ProviderURL.normalize(draft.jira.siteURL, field: "Jira site URL").absoluteString
            draft.jira.email = draft.jira.email.trimmingCharacters(in: .whitespaces)
            guard !draft.jira.email.isEmpty else { throw SettingsError.missing("Jira account email") }
            draft.jira.acceptanceCriteriaField = try draft.jira.validatedFieldID() ?? ""
            try requireToken(typed: jiraToken, kind: .jira, name: "Jira API token")
        }
    }

    private func requireToken(typed: String, kind: TicketProviderKind, name: String) throws {
        let hasTyped = !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasTyped || hasStoredToken(kind) else { throw SettingsError.missing(name) }
    }

    private func refreshStoredTokens() {
        storedTokens = Set(CredentialAccount.allCases.filter { account in
            (try? credentials.secret(for: account))??.isEmpty == false
        })
    }
}

extension TicketProviderKind {
    var credentialAccount: CredentialAccount {
        switch self {
        case .shortcut: .shortcutToken
        case .jira: .jiraToken
        }
    }
}
