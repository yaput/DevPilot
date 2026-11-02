import Foundation
import Security
import Synchronization

/// A Keychain item name. Provider tokens are fixed; repositories add their own named secrets
/// (database password, QA login) that only DevPilot's own code ever reads.
public struct CredentialAccount: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let shortcutToken = CredentialAccount(rawValue: "shortcut.apiToken")
    public static let jiraToken = CredentialAccount(rawValue: "jira.apiToken")
    public static let providerTokens: [CredentialAccount] = [.shortcutToken, .jiraToken]

    /// `repo.<repositoryID>.<name>`, e.g. the database password for one repository.
    public static func repository(_ repositoryID: String, _ name: String) -> CredentialAccount {
        CredentialAccount(rawValue: "repo.\(repositoryID).\(name)")
    }
}

public protocol CredentialStore: Sendable {
    func secret(for account: CredentialAccount) throws -> String?
    func setSecret(_ secret: String, for account: CredentialAccount) throws
    func deleteSecret(for account: CredentialAccount) throws
}

public struct CredentialStoreError: Error, LocalizedError, Equatable {
    public let status: OSStatus

    public var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
        return "Keychain error \(status): \(message)"
    }
}

/// All of DevPilot's secrets in one generic-password item of the login keychain (scoped to
/// `service`, the bundle identifier), read once and then kept in memory. One item means the
/// Keychain asks at most once, not once per secret. Items from older versions (one per secret)
/// are moved into it on first use and then deleted.
public final class KeychainCredentialStore: CredentialStore {
    static let vaultAccount = "devpilot.vault"
    private let service: String
    /// The vault once read, or why it couldn't be (not retried until the next launch, so a
    /// refused Keychain prompt doesn't come back on every lookup).
    private let cache = Mutex<Result<[String: String], CredentialStoreError>?>(nil)

    public init(service: String) {
        self.service = service
    }

    public func secret(for account: CredentialAccount) throws -> String? {
        try cache.withLock { cached in
            try loaded(&cached)[account.rawValue]
        }
    }

    public func setSecret(_ secret: String, for account: CredentialAccount) throws {
        try cache.withLock { cached in
            var secrets = try loaded(&cached)
            secrets[account.rawValue] = secret
            try save(secrets)
            cached = .success(secrets)
        }
    }

    public func deleteSecret(for account: CredentialAccount) throws {
        try cache.withLock { cached in
            var secrets = try loaded(&cached)
            guard secrets.removeValue(forKey: account.rawValue) != nil else { return }
            try save(secrets)
            cached = .success(secrets)
        }
    }

    // MARK: - Vault item

    private func loaded(_ cached: inout Result<[String: String], CredentialStoreError>?) throws -> [String: String] {
        if let cached { return try cached.get() }
        do {
            var secrets = try readData(account: Self.vaultAccount).map {
                try JSONDecoder().decode([String: String].self, from: $0)
            } ?? [:]
            try moveOlderItems(into: &secrets)
            cached = .success(secrets)
            return secrets
        } catch let error as CredentialStoreError {
            cached = .failure(error)
            throw error
        }
    }

    private func save(_ secrets: [String: String]) throws {
        let data = try JSONEncoder().encode(secrets)
        let query = baseQuery(account: Self.vaultAccount)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            item[kSecAttrLabel as String] = "DevPilot secrets"
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw CredentialStoreError(status: addStatus) }
        } else if status != errSecSuccess {
            throw CredentialStoreError(status: status)
        }
    }

    /// One item per secret (older versions): copied into the vault, then deleted. An item that
    /// can't be read (access denied) is left in place and tried again next launch. Listing
    /// items reads only their names, which never prompts.
    private func moveOlderItems(into secrets: inout [String: String]) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            if status == errSecItemNotFound { return }
            throw CredentialStoreError(status: status)
        }
        var moved: [String] = []
        for account in items.compactMap({ $0[kSecAttrAccount as String] as? String }) where account != Self.vaultAccount {
            if let data = try? readData(account: account) {
                // A value already in the vault is newer.
                if secrets[account] == nil { secrets[account] = String(decoding: data, as: UTF8.self) }
                moved.append(account)
            }
        }
        guard !moved.isEmpty else { return }
        try save(secrets)
        for account in moved {
            query = baseQuery(account: account)
            SecItemDelete(query as CFDictionary)
        }
    }

    private func readData(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw CredentialStoreError(status: status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

public final class InMemoryCredentialStore: CredentialStore {
    private let secrets = Mutex<[CredentialAccount: String]>([:])

    public init(_ initial: [CredentialAccount: String] = [:]) {
        secrets.withLock { $0 = initial }
    }

    public func secret(for account: CredentialAccount) throws -> String? {
        secrets.withLock { $0[account] }
    }

    public func setSecret(_ secret: String, for account: CredentialAccount) throws {
        secrets.withLock { $0[account] = secret }
    }

    public func deleteSecret(for account: CredentialAccount) throws {
        secrets.withLock { $0[account] = nil }
    }
}
