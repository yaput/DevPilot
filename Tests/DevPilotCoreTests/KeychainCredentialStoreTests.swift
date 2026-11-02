import Foundation
import Security
import Testing
@testable import DevPilotCore

/// Uses the real login keychain under a throwaway service name, removed afterwards.
struct KeychainCredentialStoreTests {
    let service = "dev.devpilot.tests.\(UUID().uuidString)"

    func items() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return [] }
        return ((result as? [[String: Any]]) ?? []).compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    func removeAll() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }

    @Test func allSecretsShareOneItem() throws {
        defer { removeAll() }
        let store = KeychainCredentialStore(service: service)
        try store.setSecret("token-1", for: .shortcutToken)
        try store.setSecret("pw", for: .repository("r1", "qa_password"))
        try store.setSecret("pw-2", for: .repository("r1", "qa_password"))
        #expect(items() == [KeychainCredentialStore.vaultAccount])

        // A fresh store (a new launch) reads the same values from the one item.
        let reopened = KeychainCredentialStore(service: service)
        #expect(try reopened.secret(for: .shortcutToken) == "token-1")
        #expect(try reopened.secret(for: .repository("r1", "qa_password")) == "pw-2")
        #expect(try reopened.secret(for: .jiraToken) == nil)
        try reopened.deleteSecret(for: .shortcutToken)
        #expect(try KeychainCredentialStore(service: service).secret(for: .shortcutToken) == nil)
    }

    @Test func olderPerSecretItemsAreMovedIn() throws {
        defer { removeAll() }
        for (account, value) in [("jira.apiToken", "jira-1"), ("repo.r1.db_password", "db-1")] {
            let status = SecItemAdd([
                kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: account, kSecValueData as String: Data(value.utf8),
            ] as CFDictionary, nil)
            #expect(status == errSecSuccess)
        }
        let store = KeychainCredentialStore(service: service)
        #expect(try store.secret(for: .jiraToken) == "jira-1")
        #expect(try store.secret(for: .repository("r1", "db_password")) == "db-1")
        #expect(items() == [KeychainCredentialStore.vaultAccount])
    }
}
