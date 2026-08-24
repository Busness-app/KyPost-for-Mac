//
//  LockoutPolicy.swift
//  KyPost
//
//  Escalating-delay and eventual-wipe curve for wrong app-lock PIN attempts.
//  Swift port of kypost-android's security/LockoutPolicy.kt.
//
//  **This reverses an earlier decision in this app.** AppLockStore and the
//  README both said rate-limiting and lockout were the OS's job, because
//  verification was LAContext's. With an app-lock PIN of our own there is no
//  OS counter to lean on: the passcode ladder throttles guesses at the
//  passcode, not at this app's PIN, and a PIN checked in-process is otherwise
//  an unthrottled oracle. Both documents are updated rather than quietly
//  edited — see README's "Require Unlock to Open".
//

import Foundation

nonisolated enum LockoutPolicy {
    /// Attempts 1–2 are free; typos happen. From the third on, each wrong
    /// attempt costs the next entry here, and the last value repeats.
    private static let delaysMillis: [Int64] = [30_000, 60_000, 300_000, 900_000, 1_800_000]
    private static let firstDelayedAttempt = 3

    /// Consecutive wrong attempts — no intervening success — that wipe local
    /// data.
    static let wipeThreshold = 10

    static func delayMillis(forAttemptCount attempts: Int) -> Int64 {
        guard attempts >= firstDelayedAttempt else { return 0 }
        let index = min(attempts - firstDelayedAttempt, delaysMillis.count - 1)
        return delaysMillis[index]
    }

    static func shouldWipe(attemptCount: Int) -> Bool { attemptCount >= wipeThreshold }
}
