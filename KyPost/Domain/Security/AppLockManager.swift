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

nonisolated struct LocalAuthenticationAuthenticator: DeviceAuthenticating {
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

    /// Consecutive failed unlock attempts, reset by any success.
    ///
    /// Drives UnlockView's escape hatch. A device whose biometric enrolment
    /// changed, or whose passcode was removed, fails `evaluatePolicy` every
    /// time — and since the lock's own settings live behind the lock, the user
    /// would have no way back at all. Not a lockout counter: the OS owns
    /// rate-limiting, this only decides when to offer the reset.
    private(set) var failedUnlockAttempts = 0

    /// Whether to offer the destructive reset (see
    /// `AppEnvironment.resetAfterFailedUnlock`).
    var shouldOfferReset: Bool { failedUnlockAttempts >= 3 }

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

    /// The unsealed OpenPGP key holder, cleared whenever the lock engages.
    ///
    /// Injected so a test can prove it happens. Defaulted to the shared
    /// instance so no caller has to remember to pass it — the clearing lives
    /// inside `lock()` rather than behind the `onLock` callback for the same
    /// reason: Android's equivalent holder was missed by a path that forgot to
    /// call it, and the wipe then reported success with the account's private
    /// key still in the process heap.
    private let enrollmentSession: EnrollmentSession

    init(
        store: AppLockStore,
        authenticator: any DeviceAuthenticating = LocalAuthenticationAuthenticator(),
        enrollmentSession: EnrollmentSession = .shared
    ) {
        self.store = store
        self.authenticator = authenticator
        self.enrollmentSession = enrollmentSession
        isLockEnabled = store.lockEnabled
        isLocked = store.lockEnabled
    }

    /// Engages the lock (backgrounding on iOS, screen lock on macOS).
    /// No-op while the feature is off.
    func lock() {
        // Before the early return, deliberately. The plaintext private key is
        // dropped whenever this is called, whether or not the app lock feature
        // is switched on and whether or not the lock was already engaged —
        // those are settings about the UI gate, not a reason to keep an
        // unsealed key in memory.
        enrollmentSession.clear()
        guard isLockEnabled, !isLocked else { return }
        isLocked = true
        cachedGatedSecret = nil
        onLock?()
    }

    @discardableResult
    func requestUnlock() async -> Bool {
        guard isLocked else { return true }
        guard await authenticator.authenticate(reason: String(localized: "Unlock KyPost")) else {
            failedUnlockAttempts += 1
            return false
        }
        // Repopulate the gated secret before clearing the lock — this is the
        // one point the OS may prompt for presence a second time, and it is
        // the *only* place the in-memory copy can come back (the early return
        // above skips it once unlocked). Declining that prompt has to leave
        // the app locked: unlocking without the secret produces an app that
        // looks fine and silently no-ops every relay call, with no way to
        // retry short of locking and unlocking again.
        if let loadGatedSecret, cachedGatedSecret == nil {
            guard let secret = loadGatedSecret() else {
                failedUnlockAttempts += 1
                return false
            }
            cachedGatedSecret = secret
        }
        failedUnlockAttempts = 0
        isLocked = false
        onUnlock?()
        return true
    }

    /// Re-authenticates for a single destructive action without touching lock
    /// state. Turning the lock off already required this; the actions sitting
    /// beside it in Preferences — Remove Pairing (which discards the pinned
    /// SPKI hash and forces an unpinned re-pair), Forget This Computer, Remove
    /// Exported Contacts, and turning Hostile Location Protection off — did
    /// not, which made the lock's protection inconsistent for anyone who
    /// reached Preferences while it was engaged.
    ///
    /// A no-op when the lock feature is off: the user has not asked for this
    /// class of protection, and prompting anyway would just be friction.
    func confirmWithDeviceAuth(reason: String) async -> Bool {
        guard isLockEnabled else { return true }
        return await authenticator.authenticate(reason: reason)
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
        return applyLockEnabled(enabled)
    }

    /// Turns the lock off for a caller that has already authenticated.
    ///
    /// Security settings turns the credential gate off in the same step, and
    /// that downgrade has to happen *after* an authentication, not before —
    /// while still costing the user one prompt rather than two. Deliberately
    /// not a flag on `setLockEnabled`: a boolean that decides whether
    /// authentication happens is the last parameter anyone should be able to
    /// pass by accident.
    @discardableResult
    func disableLockAfterAuthentication() -> Bool {
        applyLockEnabled(false)
    }

    private func applyLockEnabled(_ enabled: Bool) -> Bool {
        do {
            try store.setLockEnabled(enabled)
        } catch {
            Log.app.error("Could not persist app-lock setting: \(error.localizedDescription)")
            return false
        }
        isLockEnabled = enabled
        if !enabled {
            isLocked = false
            failedUnlockAttempts = 0
        }
        return true
    }
}
