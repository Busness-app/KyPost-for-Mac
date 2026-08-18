//
//  EnrollmentSession.swift
//  KyPost
//
//  Holds the opened OpenPGP private key for one unlock session. Swift port of
//  kypost-android's pgp/EnrollmentSession.kt.
//
//  The plaintext lifetime is the real exposure, not how often the biometric
//  prompt appears — so the window is the one the user already configured under
//  "Lock after: …" rather than a second concept of its own.
//
//  Held as bytes so `clear()` can zero them. A `String`'s storage cannot be
//  wiped: one would survive in the heap until the collector got to it, and in
//  any dump taken after the app locked.
//

import Foundation
import Synchronization

/// Process-wide holder for the unsealed private key.
///
/// A `final class` with a lock rather than an actor: every caller is already on
/// the main actor or inside a synchronous decrypt, and an actor would make
/// `isHeld` an `await` — which is exactly the kind of suspension point that
/// invites a caller to check presence, hop, and then act on a key that was
/// cleared in between.
nonisolated final class EnrollmentSession: Sendable {
    static let shared = EnrollmentSession()

    private let state = Mutex(Storage())

    private struct Storage {
        var key: [UInt8] = []
    }

    /// True while a key is held, **without minting a copy to answer it.**
    /// Use this rather than `withKey { $0 != nil }` for a presence check: that
    /// would materialise the private key purely to throw it away.
    var isHeld: Bool {
        state.withLock { !$0.key.isEmpty }
    }

    /// Clears first, so replacing a key does not strand the previous one.
    func put(armoredKey: String) {
        state.withLock {
            $0.key.resetBytes(in: 0..<$0.key.count)
            $0.key = Array(armoredKey.utf8)
        }
    }

    /// Lends the key for the duration of `body`.
    ///
    /// Scoped rather than returned so no copy outlives the call that needed it.
    /// The bytes handed over are still a copy — the crypto library takes
    /// `Data`, and there is no way to feed it storage this type controls — but
    /// its lifetime is one decrypt rather than the life of the session.
    func withKey<T>(_ body: (Data?) throws -> T) rethrows -> T {
        try state.withLock { storage in
            guard !storage.key.isEmpty else { return try body(nil) }
            var copy = Data(storage.key)
            defer { copy.resetBytes(in: 0..<copy.count) }
            return try body(copy)
        }
    }

    /// Zeroes the key and forgets it.
    ///
    /// Every session boundary must call this: the app lock, backgrounding,
    /// memory pressure, a security wipe, and unpairing. On Android the
    /// equivalent holder was missed by the wipe path, which then reported
    /// "Complete" with the account's private key still in the process heap —
    /// the failure this comment exists to stop recurring here.
    func clear() {
        state.withLock {
            $0.key.resetBytes(in: 0..<$0.key.count)
            $0.key = []
        }
    }
}

private extension Array where Element == UInt8 {
    /// Overwrites in place. `Array` has no `resetBytes`, and assigning a fresh
    /// array would leave the old buffer intact for the allocator to hand out.
    mutating func resetBytes(in range: Range<Int>) {
        guard !isEmpty else { return }
        for index in range { self[index] = 0 }
    }
}
