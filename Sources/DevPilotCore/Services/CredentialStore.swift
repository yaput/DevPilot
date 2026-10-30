import Foundation
import Security
import Synchronization

public enum CredentialAccount: String, Sendable, CaseIterable {
    case shortcutToken = "shortcut.apiToken"
    case jiraToken = "jira.apiToken"
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

/// Generic-password items in the login keychain, scoped to `service` (the bundle identifier).
public struct KeychainCredentialStore: CredentialStore {
    private let service: String

    public init(service: String) {
        self.service = service
    }

    public func secret(for account: CredentialAccount) throws -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return (result as? Data).map { String(decoding: $0, as: UTF8.self) }
        case errSecItemNotFound:
            return nil
        default:
            throw CredentialStoreError(status: status)
        }
    }

    public func setSecret(_ secret: String, for account: CredentialAccount) throws {
        let data = Data(secret.utf8)
        let status = SecItemUpdate(baseQuery(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery(account)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            item[kSecAttrLabel as String] = "DevPilot \(account.rawValue)"
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw CredentialStoreError(status: addStatus) }
        } else if status != errSecSuccess {
            throw CredentialStoreError(status: status)
        }
    }

    public func deleteSecret(for account: CredentialAccount) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialStoreError(status: status) }
    }

    private func baseQuery(_ account: CredentialAccount) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
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
