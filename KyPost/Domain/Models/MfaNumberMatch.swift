//
//  MfaNumberMatch.swift
//  KyPost
//
//  The number-matching choice set for one MFA challenge. Swift port of
//  kypost-android's push/MfaNumberMatch.kt.
//

import Foundation

/// A bare Approve button asks for a tap, and a tap is exactly what an
/// MFA-fatigue attack harvests: the user is woken at 03:00, has approved this
/// same contentless prompt fifty times legitimately, and taps. Number matching
/// replaces the tap with a discrimination that can only be made by someone
/// looking at the screen that started the sign-in.
///
/// **Every value comes from the server.** This client used to invent decoys
/// from a linear congruential generator seeded on the challenge id whenever
/// the server sent too few — which made the wrong answers derivable by anyone
/// who knew the id, and therefore the right one derivable by elimination. That
/// is the whole guarantee of number matching, handed away. The server mints
/// the correct value and both decoys from `crypto/rand`
/// (kypost-server `mfa.newNumberMatch`) and verifies the answer itself
/// (`Store.ResolvePushWithMatch`), so a challenge that does not carry all
/// three is one this client cannot offer an approval for at all: `options`
/// returns nil and the caller must leave only Deny available rather than
/// falling back to a button the server will refuse.
///
/// Digit width is whatever the server used, not a hardcoded 2. Android pinned
/// it in three places across two repositories with no negotiation, so widening
/// the server's value space — the obvious next hardening, since two digits is
/// only 100 values — would have silently disabled approval on every deployed
/// client.
enum MfaNumberMatch {
    static let choiceCount = 3

    /// The tiles to render, in the order to render them, or nil when `correct`
    /// and `serverDecoys` do not describe a complete `choiceCount`-way choice.
    ///
    /// Order is randomised per call. `shuffle` is injectable only so tests can
    /// pin it; callers must shuffle **once** and keep the result for the life
    /// of the challenge, or a redraw would reorder the tiles under the user's
    /// finger. `MfaApprovalViewModel` holds it in a `let` for that reason.
    ///
    /// The previous ordering — sorting on a hash of `(challengeId, value)` —
    /// did not randomise anything. The hash of `challengeId + value` expands
    /// to `H(challengeId) * 31^n + f(value)`, and every candidate has the same
    /// width, so the challenge-id term is an identical additive offset on all
    /// three and cancels out of every comparison. What was left was a sort on
    /// `f(value)`, which for equal-width digit strings is monotone in the
    /// value: the tiles came out in numeric order, on every challenge.
    static func options(
        correct: String,
        serverDecoys: [String],
        shuffle: ([String]) -> [String] = { $0.shuffled() }
    ) -> [String]? {
        guard MfaChallenge.isValidMatchDigits(correct) else { return nil }

        var decoys: [String] = []
        for decoy in serverDecoys
        where decoy != correct && decoy.count == correct.count && !decoys.contains(decoy) {
            decoys.append(decoy)
        }

        // Exactly, not at least: fewer is an incomplete challenge, and more
        // means the server and this client disagree about the shape of the
        // choice.
        guard decoys.count == choiceCount - 1 else { return nil }
        return shuffle(decoys + [correct])
    }
}
