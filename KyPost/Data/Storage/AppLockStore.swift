//
//  AppLockStore.swift
//  KyPost
//
//  Keychain-backed app-lock settings (security-hardening plan, Task 1).
//  Keys are a binding contract: appLock.enabled,
//  appLock.credentialGateEnabled. Deliberately no PIN or lockout fields —
//  verification is LAContext's job, lockout is the OS's (see the design's
//  "lean on the platform passcode" decision).
//

import Foundation

final class AppLockStore: Sendable {
    private enum Key {
        static let lockEnabled = "appLock.enabled"
        static let credentialGateEnabled = "appLock.credentialGateEnabled"
    }

    private let keychain: KeychainStorage

    init(keychain: KeychainStorage) {
        self.keychain = keychain
    }

    /// Feature 1: Require Unlock to Open. A read failure reports false
    /// (unlocked) — a Keychain outage severe enough to break this read also
    /// breaks the pairing credential, so the app is unusable either way and
    /// locking the user out on top of it helps nobody.
    var lockEnabled: Bool {
        (try? keychain.string(forKey: Key.lockEnabled)) == "true"
    }

    func setLockEnabled(_ enabled: Bool) throws {
        try keychain.set(enabled ? "true" : "false", forKey: Key.lockEnabled)
    }

    /// Feature 3: Require unlock to receive push/MFA. Stored here so the
    /// store's shape is final from day one; wired up by the credential-gate
    /// task.
    var credentialGateEnabled: Bool {
        (try? keychain.string(forKey: Key.credentialGateEnabled)) == "true"
    }

    func setCredentialGateEnabled(_ enabled: Bool) throws {
        try keychain.set(enabled ? "true" : "false", forKey: Key.credentialGateEnabled)
    }
}
