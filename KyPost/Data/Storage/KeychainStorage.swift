//
//  KeychainStorage.swift
//  KyPost
//
//  Generic-password Keychain wrapper (spec §1 Secure Storage). Items are
//  stored in the data-protection keychain, this-device-only.
//
//  ponytail: spec suggests .biometryCurrentSet access control, but background
//  pull polling (spec §3) must read sub/hash without user presence. Using
//  kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly instead; upgrade path is
//  splitting biometry-gated items into a separate access group in v2.
//

import Foundation
import Security

nonisolated final class KeychainStorage: Sendable {
    struct KeychainError: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String { "Keychain error (OSStatus \(status))" }
    }

    private let service: String

    init(service: String = (Bundle.main.bundleIdentifier ?? "org.kysecurity.mail") + ".secure") {
        self.service = service
    }

    func set(_ value: String, forKey key: String) throws {
        try setData(Data(value.utf8), forKey: key)
    }

    func string(forKey key: String) throws -> String? {
        guard let data = try data(forKey: key) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func setData(_ data: Data, forKey key: String) throws {
        var query = baseQuery(forKey: key)
        let attributes: [CFString: Any] = [kSecValueData: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            query[kSecValueData] = data
            query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        default:
            throw KeychainError(status: updateStatus)
        }
    }

    func data(forKey key: String) throws -> Data? {
        var query = baseQuery(forKey: key)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    /// Removes an item; missing items are not an error.
    func remove(_ key: String) throws {
        let status = SecItemDelete(baseQuery(forKey: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    // MARK: - Private

    private func baseQuery(forKey key: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecUseDataProtectionKeychain: true,
        ]
    }
}
