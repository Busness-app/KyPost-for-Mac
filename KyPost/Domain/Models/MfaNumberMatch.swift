//
//  MfaNumberMatch.swift
//  KyPost
//
//  The number-matching choice set for one MFA challenge. Swift port of
//  kypost-android's MfaNumberMatch, deliberately using the same derivation so
//  both clients render the same options for the same challenge.
//

import Foundation

/// A bare Approve button asks for a tap, and a tap is exactly what an
/// MFA-fatigue attack harvests: the user is woken at 03:00, has approved this
/// same contentless prompt fifty times legitimately, and taps. Number matching
/// replaces the tap with a discrimination that can only be made by someone
/// looking at the screen that started the sign-in.
///
/// Derived deterministically from the challenge id when the server sends too
/// few decoys, so the same challenge always renders the same options — a view
/// redraw must not reshuffle the buttons under the user's finger.
enum MfaNumberMatch {
    static let choiceCount = 3

    /// Returns nil when the server supplied no usable `correct` value, meaning
    /// number matching is unavailable and the caller must fall back to plain
    /// approve/deny.
    static func options(challengeId: String, correct: String, serverDecoys: [String]) -> [String]? {
        guard correct.count == MfaChallenge.matchDigitsLength,
              correct.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return nil
        }

        var decoys: [String] = []
        for decoy in serverDecoys where decoy != correct && !decoys.contains(decoy) {
            decoys.append(decoy)
        }

        // Deterministic filler seeded from the challenge id, matching Android's
        // LCG so the two clients agree. Overflow is the intent here, hence the
        // wrapping operators.
        var seed = challengeId.unicodeScalars.reduce(Int64(7)) { acc, scalar in
            acc &* 31 &+ Int64(scalar.value)
        }
        while decoys.count < choiceCount - 1 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            // Int, not Int64, into String(format:): "%d" takes a C int, so a
            // 64-bit argument there is a format-specifier mismatch. The value
            // is already reduced mod 100, so the conversion cannot trap.
            let candidate = String(format: "%02d", Int(abs(seed / 65_536) % 100))
            if candidate != correct && !decoys.contains(candidate) {
                decoys.append(candidate)
            }
        }

        let choices = Array(decoys.prefix(choiceCount - 1)) + [correct]
        // Sort by a hash of (challengeId, value) so the correct answer is not
        // always in the same position, but the order never changes for a given
        // challenge. Swift's sort is not stable, so equal hashes tie-break on
        // the value itself rather than leaving the order to the algorithm.
        return choices.sorted { lhs, rhs in
            let left = positionHash(challengeId, lhs)
            let right = positionHash(challengeId, rhs)
            return left == right ? lhs < rhs : left < right
        }
    }

    private static func positionHash(_ challengeId: String, _ value: String) -> Int32 {
        (challengeId + value).unicodeScalars.reduce(Int32(17)) { acc, scalar in
            acc &* 31 &+ Int32(truncatingIfNeeded: scalar.value)
        }
    }
}
