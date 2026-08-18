//
//  PgpSignatureState.swift
//  KyPost
//
//  What a message's OpenPGP signature actually claims. Swift port of
//  kypost-android's pgp/PgpMessageState.kt (the PgpSignatureState half) and
//  pgp/SignerBinding.kt.
//

import Foundation

/// Six states, not a verified/unverified pair. The distinction that matters is
/// between *identity* (someone confirmed this key out of band) and *continuity*
/// (same key as last time), because most keys arrive by Autocrypt harvest and a
/// flat "verified" would overclaim for nearly all of them.
nonisolated enum PgpSignatureState: Equatable, Sendable {
    /// Unsigned, or no opinion expressed. Nothing to say.
    case none

    /// Signed by a key bound to the sender that the user confirmed out of band
    /// — by reading a fingerprint aloud or scanning a QR code. **The only
    /// state that claims identity.**
    case verifiedConfirmed

    /// Signed by a bound key still matching its TOFU pin, which nobody ever
    /// confirmed. Claims **continuity**, not identity: the same key as last
    /// time.
    case verifiedSeenBefore

    /// No key bound to this sender at all. An ordinary correspondent not yet
    /// in the address book, a key that rotated before harvest, and a forged
    /// `From` are locally indistinguishable — so this is **not an accusation**.
    case signerUnknown

    /// A key IS bound to this sender and no longer matches its TOFU pin. The
    /// one alarm worth raising.
    case keyChanged

    /// Signed, but it does not verify against the bound key.
    case invalid
}

/// One address-bound contact key as the server ships it.
///
/// `addresses` is the binding the **server's** address book computed. The
/// client must not re-derive it from the key's own User IDs: one key can
/// self-assert two User IDs, so a binding taken from the key material is
/// forgeable.
///
/// `conflict` means the stored key no longer matches its TOFU pin. Such an
/// entry carries no `publicKey` and is never offered to a signature check — it
/// exists so the reader can say the key changed rather than silently reporting
/// an unknown signer.
nonisolated struct SignerKey: Equatable, Sendable {
    var addresses: [String] = []
    var publicKey: String = ""
    var verified = false
    var source: String = ""
    var conflict = false
}

/// The raw signature facts, independent of who is bound to them.
nonisolated struct RawSignature: Equatable, Sendable {
    var present = false
    var valid = false
    /// The key id that made the signature, as the payload reports it.
    var signerKeyID: String = ""
}

/// The signature verdict for a message being displayed as being from a sender
/// **the server has already resolved**.
///
/// `signerKeys` arrives already narrowed to that sender. This function does not
/// know the sender's address and **must not learn it**.
///
/// Android's client used to parse the raw `From` header itself. A differential
/// harness over 111 adversarial headers found 27 divergences from the server's
/// parser — most seriously RFC 5322 comments, where `Bob (Eve <eve@evil>)
/// <bob@x>` is valid, the server binds `bob@x`, and the client bound
/// `eve@evil`, letting any contact forge a verified badge for anyone. Three fix
/// rounds each closed one construct and opened another.
///
/// **A second parser deciding the same binding is the defect. Do not
/// reintroduce one.** This app's two address parsers are for display
/// (`RelayMailSource.splitSender`) and for outgoing compose
/// (`EmailAddress.parse`); neither may ever reach this function.
///
/// `keyIDs` extracts every usable key id from an armored public key. It is
/// injected because doing it properly needs an OpenPGP implementation, which
/// this app does not have until the crypto core lands; the ordering rules
/// below are the part worth having early, and they are testable without it.
nonisolated func signatureState(
    signature: RawSignature,
    signerKeys: [SignerKey],
    keyIDs: (String) -> Set<String>
) -> PgpSignatureState {
    guard signature.present else { return .none }
    guard !signerKeys.isEmpty else { return .signerUnknown }

    // A conflict outranks a good key for the same sender. Two entries for one
    // address means one of them is a key that changed, and reporting the
    // survivor as verified would hide precisely the event worth reporting.
    if signerKeys.contains(where: \.conflict) { return .keyChanged }

    let signedBy = signerKeys.filter { keyIDs($0.publicKey).contains(signature.signerKeyID) }
    guard !signedBy.isEmpty else { return .signerUnknown }
    guard signature.valid else { return .invalid }

    return signedBy.contains(where: \.verified) ? .verifiedConfirmed : .verifiedSeenBefore
}

// MARK: - Presentation

/// SF Symbol for an inbox row, or nil for no marker.
///
/// `signerUnknown` deliberately does **not** mark: it is the ordinary state for
/// a correspondent not yet in the address book, and a glyph on most rows
/// carries nothing actionable.
nonisolated func signatureRowSymbol(_ state: PgpSignatureState) -> String? {
    switch state {
    case .keyChanged, .invalid: "exclamationmark.triangle.fill"
    case .none, .verifiedConfirmed, .verifiedSeenBefore, .signerUnknown: nil
    }
}

/// Short label for the reader's signature pill, or nil when there is nothing
/// worth saying.
///
/// The wording is the contract. `verifiedSeenBefore` must not read as an
/// identity claim, and `signerUnknown` must not read as an accusation.
nonisolated func signatureLabel(_ state: PgpSignatureState) -> String? {
    switch state {
    case .none: nil
    case .verifiedConfirmed: "Signed — you confirmed this key"
    case .verifiedSeenBefore: "Signed — same key as last time"
    case .signerUnknown: "Signed by a key you haven't saved"
    case .keyChanged: "This sender's key has changed"
    case .invalid: "Signature doesn't match"
    }
}

/// Whether the state is an alarm rather than information.
nonisolated func signatureIsAlarming(_ state: PgpSignatureState) -> Bool {
    state == .keyChanged || state == .invalid
}
