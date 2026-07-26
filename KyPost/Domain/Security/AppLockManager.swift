//
//  AppLockManager.swift
//  KyPost
//
//  App-lock state and the unlock decision (security-hardening plan, Task 1).
//  "Locked" means "has the device owner authenticated since the lock last
//  engaged" — in-memory only, never persisted. Verification is
//  LAContext.deviceOwnerAuthentication (biometric first, passcode fallback);
//  rate-limiting and lockout are the OS's, not ours.
//

import Foundation
import LocalAuthentication
import Observation
import os

/// How the app verifies the device owner. Production wraps `LAContext`;
/// tests inject a stub (LAContext cannot run headless).
protocol DeviceAuthenticating {
    /// Whether the device has any owner authentication configured at all
    /// (passcode/login password at minimum).
    func canAuthenticate() -> Bool
    func authenticate(reason: String) async -> Bool
}

struct LocalAuthenticationAuthenticator: DeviceAuthenticating {
    func canAuthenticate() -> Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    func authenticate(reason: String) async -> Bool {
        // A fresh context per call: LAContext is single-use once invalidated,
        // and reuse can return stale grace-period results.
        let context = LAContext()
        return (try? await context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: reason
        )) ?? false
    }
}

@Observable
@MainActor
final class AppLockManager {
    private let store: AppLockStore
    private let authenticator: any DeviceAuthenticating

    private(set) var isLocked: Bool
    /// Observable mirror of `store.lockEnabled` so settings toggles track it
    /// (the Keychain-backed store itself is not observation-tracked).
    private(set) var isLockEnabled: Bool

    /// Runs after a successful unlock — the lock-trigger task wires the
    /// deferred foreground sync here.
    var onUnlock: (() -> Void)?
    /// Runs when the lock engages.
    var onLock: (() -> Void)?

    /// Credential gate: the device secret, held in memory only while
    /// unlocked. Dropped the instant the lock engages; reloaded through the
    /// access-controlled Keychain item on unlock.
    private(set) var cachedGatedSecret: String?
    /// Reads the access-controlled item (may prompt for user presence).
    /// Installed by CredentialGateService while the gate is on.
    var loadGatedSecret: (() -> String?)?

    func cacheGatedSecret(_ secret: String?) {
        cachedGatedSecret = secret
    }

    init(
        store: AppLockStore,
        authenticator: any DeviceAuthenticating = LocalAuthenticationAuthenticator()
    ) {
        self.store = store
        self.authenticator = authenticator
        isLockEnabled = store.lockEnabled
        isLocked = store.lockEnabled
    }

    /// Engages the lock (backgrounding on iOS, screen lock on macOS).
    /// No-op while the feature is off.
    func lock() {
        guard isLockEnabled, !isLocked else { return }
        isLocked = true
        cachedGatedSecret = nil
        onLock?()
    }

    @discardableResult
    func requestUnlock() async -> Bool {
        guard isLocked else { return true }
        guard await authenticator.authenticate(reason: String(localized: "Unlock KyPost")) else {
            return false
        }
        isLocked = false
        // Repopulate the gated secret before the deferred sync runs — this
        // is the one point the OS may prompt for presence a second time.
        if cachedGatedSecret == nil {
            cachedGatedSecret = loadGatedSecret?()
        }
        onUnlock?()
        return true
    }

    /// Enabling requires the device to have owner authentication configured;
    /// disabling requires re-authenticating first. Returns whether the change
    /// took, so the settings UI shows an inline explanation instead of a
    /// silent no-op. Enabling does not lock the running session — the user
    /// who just toggled is present; the next trigger locks.
    @discardableResult
    func setLockEnabled(_ enabled: Bool) async -> Bool {
        if enabled {
            guard authenticator.canAuthenticate() else { return false }
        } else {
            guard await authenticator.authenticate(
                reason: String(localized: "Turn off Require Unlock to Open")
            ) else { return false }
        }
        do {
            try store.setLockEnabled(enabled)
        } catch {
            Log.app.error("Could not persist app-lock setting: \(error.localizedDescription)")
            return false
        }
        isLockEnabled = enabled
        if !enabled {
            isLocked = false
        }
        return true
    }
}
