//
//  SpkiPin.swift
//  KyPost
//
//  The pairing link's `pin=` parameter, normalised to the representation
//  this app actually compares against.
//
//  Two encodings of the same 32 bytes meet here, and confusing them fails
//  CLOSED on every pairing rather than loudly:
//
//    * the relay publishes `sha256/<base64>` over the certificate's DER
//      SubjectPublicKeyInfo (kypost-server `pairing_pin.go: spkiPin`), and
//      the browser percent-encodes it into the link;
//    * `PinnedSessionDelegate.spkiSHA256(ofCertificate:)` computes, stores
//      and compares LOWERCASE HEX over those same bytes.
//
//  Converting once, here, keeps the delegate on a single representation and
//  leaves its comparison a plain string equality.
//

import Foundation

enum SpkiPin {
    /// A `pin=` value as lowercase hex, or nil if it is not a well-formed
    /// base64 SHA-256.
    ///
    /// **Callers must treat nil as a refusal, not as "no pin".** Dropping an
    /// unparseable pin silently reopens the trust-on-first-use window on the
    /// one request that carries the pairing token and the push credentials —
    /// which is the entire reason the parameter exists. Android takes the
    /// same position, in the same words: "Refuse rather than ignore"
    /// (`PairingModels.kt`).
    static func normalizedHex(fromLinkValue raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.hasPrefix(prefix) ? String(trimmed.dropFirst(prefix.count)) : trimmed
        // 32 bytes of SHA-256 is exactly 43 base64 characters plus one '=' of
        // padding. The alphabet is checked before decoding rather than relying
        // on the decoder: Foundation's base64 decoder ignores some characters
        // it does not recognise instead of rejecting them, so a mangled pin
        // could otherwise decode to 32 plausible bytes. Same regex as Android.
        guard body.count == 44,
              body.dropLast().allSatisfy({ base64Alphabet.contains($0) }),
              body.hasSuffix("="),
              let data = Data(base64Encoded: body),
              data.count == 32
        else { return nil }
        return data.map { String(format: "%02x", $0) }.joined()
    }

    private static let prefix = "sha256/"
    private static let base64Alphabet = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    )
}
