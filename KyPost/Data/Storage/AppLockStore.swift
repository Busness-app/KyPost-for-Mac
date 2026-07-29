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

    /// A stored flag, or the fact that it could not be read.
    ///
    /// The distinction matters wherever a `false` triggers a *repair* rather
    /// than just a quieter UI: `errSecInteractionNotAllowed` at launch is a
    /// routine, transient status on a Mac whose Keychain is not ready yet, and
    /// collapsing it into "the user turned this off" let one flaky read move
    /// the device secret out from behind user presence for good.
    enum FlagState: Equatable {
        case on
        case off
        case unreadable
    }

    private let keychain: KeychainStorage

    init(keychain: KeychainStorage) {
        self.keychain = keychain
    }

    /// Feature 1: Require Unlock to Open. Callers that only decide what to
    /// *show* use `lockEnabled`, which still reports false on a read failure —
    /// a Keychain outage severe enough to break this read also breaks the
    /// pairing credential, so locking the user out on top of it helps nobody.
    /// Callers that act destructively must use `lockState` instead.
    var lockState: FlagState {
        do {
            return try keychain.string(forKey: Key.lockEnabled) == "true" ? .on : .off
        } catch {
            return .unreadable
        }
    }

    var lockEnabled: Bool { lockState == .on }

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
