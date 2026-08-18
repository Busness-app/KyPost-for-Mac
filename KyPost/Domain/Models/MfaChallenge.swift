//
//  MfaChallenge.swift
//  KyPost
//
//  Domain model for an MFA push approval challenge (spec §5).
//  Payload contract: { type: "mfa_challenge", challengeId: "...",
//  matchDigits: "NN", decoyDigits: "NN,NN" }. The digit width is the
//  server's choice, not a fixed 2 — see matchDigitsLengthRange.
//  Sensitive data: do NOT store challenge secret/token longer than needed.
//

import Foundation

struct MfaChallenge: Identifiable, Hashable, Sendable {
    static let payloadType = "mfa_challenge"

    /// Accepted width of a number-match value, as a range rather than the
    /// server's current 2. The width was pinned to an exact literal in three
    /// places across two repositories with no negotiation, so widening the
    /// server's value space — the obvious next hardening, since two digits is
    /// only 100 values — would have silently disabled approval on every
    /// deployed client. Matches Android's MATCH_DIGITS_MIN/MAX_LENGTH.
    static let matchDigitsLengthRange = 1...6

    /// Shape only. Whether a *set* of these adds up to an approvable challenge
    /// is `MfaNumberMatch.options`' decision.
    static func isValidMatchDigits(_ value: String) -> Bool {
        matchDigitsLengthRange.contains(value.count)
            && value.allSatisfy { $0.isASCII && $0.isNumber }
    }

    var challengeId: String
    var receivedAt: Date

    /// The digits the server is simultaneously showing in the browser that
    /// started the sign-in. Empty when the server predates number matching, in
    /// which case the challenge cannot be approved from this device at all —
    /// the screen offers Deny only. There is deliberately no plain-Approve
    /// fallback: that button is the tap an MFA-fatigue attack harvests, and
    /// the server refuses a numberless approval anyway.
    ///
    /// The server verifies this value itself and refuses an approval without
    /// it, so it is not decoration: an approve that omits it is rejected.
    var matchDigits: String = ""

    /// The wrong values the approval screen offers alongside `matchDigits`.
    /// **The server mints these**; this client never invents them. Too few (or
    /// a set that does not agree with `matchDigits` on width) means the
    /// challenge is not approvable here — see `MfaNumberMatch.options`.
    var decoyDigits: [String] = []

    var id: String { challengeId }
}
