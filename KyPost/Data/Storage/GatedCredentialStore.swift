//
//  GatedCredentialStore.swift
//  KyPost
//
//  Access-controlled Keychain item for the device secret (security-
//  hardening plan, Task 6). `.userPresence` — not `.biometryCurrentSet` —
//  for parity with the LAContext.deviceOwnerAuthentication decision, so a
//  Mac with no biometric hardware still gets password-gated protection.
//  Reads prompt for user presence; writes and deletes do not.
//

import Foundation
import Security

/// Seam over the access-controlled item — real access control cannot run
/// headless, so tests stub this.
protocol GatedCredentialStoring {
    func store(_ secret: String) throws
    /// Nil when absent or when the user declines the presence prompt.
    func load() throws -> String?
    func remove() throws
}

nonisolated final class GatedCredentialStore: GatedCredentialStoring, Sendable {
    struct AccessControlError: Error {}

    private static let account = "gatedDeviceSecret"
    private let service: String

    init(service: String = (Bundle.main.bundleIdentifier ?? "org.kysecurity.mail") + ".gated") {
        self.service = service
    }

    func store(_ secret: String) throws {
        try remove()
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            nil
        ) else { throw AccessControlError() }
        var query = baseQuery()
        query[kSecAttrAccessControl] = access
        query[kSecValueData] = Data(secret.utf8)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainStorage.KeychainError(status: status)
        }
    }

    func load() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return (result as? Data).map { String(decoding: $0, as: UTF8.self) }
        case errSecItemNotFound, errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            return nil
        default:
            throw KeychainStorage.KeychainError(status: status)
        }
    }

    func remove() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStorage.KeychainError(status: status)
        }
    }

    private func baseQuery() -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: Self.account,
            kSecUseDataProtectionKeychain: true,
        ]
    }
}
