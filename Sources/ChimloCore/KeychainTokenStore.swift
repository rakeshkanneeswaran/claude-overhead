import Foundation
import Security

/// Stores a GitHub personal access token as a generic password in the user's
/// Keychain.
///
/// `AfterFirstUnlockThisDeviceOnly` lets background refreshes read the token
/// while the screen is locked, and keeps it out of backups and iCloud Keychain
/// so it never leaves this Mac.
public struct KeychainTokenStore: GitHubTokenStoring {
    public struct KeychainError: Error, Equatable, Sendable, LocalizedError {
        public let status: OSStatus

        public init(status: OSStatus) {
            self.status = status
        }

        public var errorDescription: String? {
            let message = SecCopyErrorMessageString(status, nil) as String?
            return "Keychain error \(status)\(message.map { ": \($0)" } ?? "")"
        }
    }

    public let service: String
    public let account: String

    public init(service: String = "com.rakesh.overhead.github", account: String = "personal-access-token") {
        self.service = service
        self.account = account
    }

    /// Whether a token is stored, without reading it. Asking only for the
    /// item's attributes never needs the Keychain's permission, so this never
    /// shows a dialog and never waits for one. Reading the token itself can:
    /// after an update the Keychain may ask the owner again, and a view that
    /// read it would stop the whole app until they answered.
    public func exists() -> Bool {
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    public func read() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    /// Updates the existing item when there is one, so the item keeps any
    /// access the user already granted; adds it otherwise.
    public func save(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw KeychainError(status: errSecParam) }
        let data = Data(trimmed.utf8)

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = baseQuery
            item.merge(attributes) { _, new in new }
            item[kSecAttrLabel as String] = "Claude Overhead GitHub token"
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        default:
            throw KeychainError(status: updateStatus)
        }
    }

    /// Deleting a token that is not stored is not an error.
    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
