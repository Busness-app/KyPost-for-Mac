//
//  PgpIdentityStatus.swift
//  KyPost
//
//  "Does the paired account have a PGP identity on the server?" — for the
//  self-contact's badge. Counterpart of kypost-android's
//  pgp/PgpIdentityStatus.kt.
//

import Foundation

/// Answers the question, or admits it could not be answered.
///
/// **Nil is not false.** A network failure, an unpaired device, or an
/// unreadable response must leave the caller showing whatever it already
/// showed, rather than asserting the account has no key. Rendering "no
/// identity" for "couldn't ask" is the specific mistake this type exists to
/// prevent.
///
/// This app reads it straight from `GET /api/pgp/bootstrap`'s `hasIdentity`,
/// which `PgpSendService` already caches once per session. Android instead
/// mints a PGP QR token and reads 200-vs-400, because its own `hasIdentity`
/// plumbing arrived later; the endpoint here is the same one, asked directly,
/// so there is nothing to gain by copying that indirection.
nonisolated func pgpIdentityPresent(custody: PgpKeyCustody?) -> Bool? {
    guard let custody else { return nil }
    return custody != .noIdentity
}

/// Whether a contact should show a "has a PGP key" badge.
///
/// **The account's own PGP identity is never in the contacts database.**
/// `Contact.pgpKey` — even on the self-contact — is an ordinary contact field,
/// written only when a key is attached by hand or by a QR scan, with no
/// connection to the account's real identity, which lives server-side. Reading
/// the self-contact's `pgpKey` for this badge is the bug this rule replaces:
/// it is empty for essentially every user, so the badge never appeared for
/// the one contact guaranteed to have a key.
///
/// Returns nil when the answer is unknown, so the caller can leave the badge
/// as it was instead of flashing it off.
nonisolated func contactHasLinkedPgpKey(
    contact: Contact,
    accountIdentityPresent: Bool?
) -> Bool? {
    if contact.isSelf {
        // An attached key still counts: a user who scanned their own key onto
        // their self-contact should not see the badge disappear because the
        // server check failed.
        if contact.pgpKey?.isEmpty == false { return true }
        return accountIdentityPresent
    }
    return contact.pgpKey?.isEmpty == false
}
