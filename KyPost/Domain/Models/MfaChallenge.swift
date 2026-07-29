//
//  MfaChallenge.swift
//  KyPost
//
//  Domain model for an MFA push approval challenge (spec §5).
//  Payload contract: { type: "mfa_challenge", challengeId: "...",
//  matchDigits: "NN", decoyDigits: "NN,NN" }.
//  Sensitive data: do NOT store challenge secret/token longer than needed.
//

import Foundation

struct MfaChallenge: Identifiable, Hashable, Sendable {
    static let payloadType = "mfa_challenge"

    /// Length of the number-match value. Fixed at 2 to match the server, which
    /// generates exactly two digits (kypost-server `matchDigitCount`), and the
    /// Android client, which discards anything else.
    static let matchDigitsLength = 2

    var challengeId: String
    var receivedAt: Date

    /// The digits the server is simultaneously showing in the browser that
    /// started the sign-in. Empty when the server predates number matching, in
    /// which case the approval screen falls back to a plain Approve button.
    ///
    /// The server verifies this value itself and refuses an approval without
    /// it, so it is not decoration: an approve that omits it is rejected.
    var matchDigits: String = ""

    /// Wrong options the approval screen offers alongside `matchDigits`. Empty
    /// means the client derives its own from the challenge id.
    var decoyDigits: [String] = []

    var id: String { challengeId }
}
