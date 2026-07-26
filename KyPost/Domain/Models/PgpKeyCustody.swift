//
//  PgpKeyCustody.swift
//  KyPost
//
//  Who holds the account's PGP private key, and therefore whether this client
//  may ask the relay to sign and encrypt on its behalf
//  (Client_Encrypted_Send.md "two key-custody modes").
//
//  A pure mapping of GET /api/pgp/bootstrap's hasIdentity/protection so the
//  degradation rule is testable without a network. This client never holds the
//  account's private key — see kypost-server/docs/E2E_PGP.md.
//

import Foundation

nonisolated enum PgpKeyCustody: Equatable, Sendable {
    /// No PGP identity. Plaintext send only; compose offers no toggles.
    case noIdentity

    /// The server holds the key, encrypted at rest under its own key, and
    /// signs/encrypts for the account. Native encrypted send works here.
    case serverHeld

    /// Only the user's browser can unwrap the key, from a password-derived key
    /// this client never learns. Encrypted send is impossible here; compose
    /// offers the webmail handoff instead.
    case clientHeld
}

/// Maps a bootstrap response to custody, degrading rather than guessing.
///
/// An unrecognised `protection` maps to `.clientHeld`. A future mode is far
/// more likely to be a stronger client-side one than a server-side one, and
/// reading it as client-held costs only a webmail handoff — reading it as
/// server-held would promise an encrypted send this client cannot deliver.
///
/// `nil` and empty string are distinct facts: an absent or unparseable field
/// is unknown and degrades to `.clientHeld`, but an explicitly empty string
/// means the account has no identity (the spec's custody table) and stays
/// `.noIdentity`.
nonisolated func pgpKeyCustody(hasIdentity: Bool?, protection: String?) -> PgpKeyCustody {
    guard hasIdentity == true else { return .noIdentity }
    guard let protection else { return .clientHeld }
    return switch protection.trimmingCharacters(in: .whitespaces).lowercased() {
    case "": .noIdentity
    case "server": .serverHeld
    default: .clientHeld
    }
}
