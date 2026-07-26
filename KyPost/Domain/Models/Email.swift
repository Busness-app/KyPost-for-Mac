//
//  Email.swift
//  KyPost
//
//  Domain model for a received email (spec §8 emails table).
//

import Foundation

struct Email: Identifiable, Hashable, Sendable {
    /// Relay message id.
    var serverId: String
    var folder: String
    var senderName: String
    var senderEmail: String
    var subject: String
    var body: String
    /// Raw To/Cc header strings (comma-joined, entries may be
    /// "Name <addr>"); kept for Reply All recipient building.
    var sentTo: String = ""
    var cc: String = ""
    /// Relay tab/label values; drives inbox tabs.
    var keywords: Set<String>
    var receivedAt: Date
    var read: Bool
    var starred: Bool
    /// Relay OpenPGP state. Defaults are the wire contract for a message with
    /// no OpenPGP content — see PgpMessageState.swift for what they mean
    /// together.
    var pgpEncrypted: Bool = false
    var pgpSigned: Bool = false
    var pgpVerified: Bool = false
    /// Stored but not rendered — displaying it usefully means comparing it
    /// against a contact's saved key, which belongs with the contacts work.
    var pgpSignerFingerprint: String = ""
    var pgpDecryptError: String = ""

    var id: String { serverId }
}

/// A folder/mailbox on the relay.
struct MailFolder: Hashable, Sendable {
    var name: String
}

/// Built-in relay mailboxes. Binding contract: values are the exact
/// `mailbox` parameter names the relay and the Android reference use
/// (InboxActivity switches between "INBOX"/"Junk"/"Trash").
enum StandardFolder {
    static let inbox = "INBOX"
    static let drafts = "Drafts"
    static let junk = "Junk"
    static let sent = "Sent"
    static let trash = "Trash"
    static let archive = "Archive"

    /// Human title for a mailbox path: "INBOX" → "Inbox",
    /// "Archive/Receipts" → "Receipts". The backend treats both "/" and "."
    /// as hierarchy delimiters (server.go mailboxParentPath), so both split.
    static func displayName(_ path: String) -> String {
        if path == inbox { return "Inbox" }
        return path.split(whereSeparator: { $0 == "/" || $0 == "." }).last.map(String.init) ?? path
    }
}

/// An email being composed (spec §7 SendEmailUseCase).
struct OutgoingEmail: Sendable {
    var to: [String]
    var cc: [String]
    var bcc: [String]
    var subject: String
    var body: String
    /// Relay send mode: "plain" (default), "html", or "markup".
    var mode: String = "plain"
    var attachments: [OutgoingAttachment] = []
    /// Ask the relay to encrypt this message to its recipients. The server
    /// holds the key and does the OpenPGP work; this client never does
    /// (Client_Encrypted_Send.md).
    var encrypt = false
    /// Ask the relay to sign with the account's key.
    var sign = false
    /// Consent to the relay mailing a one-time pickup link to recipients with
    /// no usable key, which stores this message's plaintext on the server for
    /// 7 days. Meaningful only with `encrypt`. Per-message by design — never
    /// remembered, never persisted.
    var allowPickupFallback = false
    /// Relay mode only: server-side categorization.
    var tab: String?
}

/// A file attached to an outgoing email; sent base64-encoded in the
/// /api/mail/send JSON body (Mobile_Mail_Relay.md, 25 MB total cap).
struct OutgoingAttachment: Hashable, Sendable {
    var name: String
    var mimeType: String
    var data: Data
}

/// Metadata for one attachment on a received email, from
/// GET /api/mail/attachments. Content downloads separately by index.
struct EmailAttachment: Identifiable, Hashable, Sendable {
    var index: Int
    var name: String
    var mimeType: String
    /// Decoded size in bytes.
    var size: Int

    var id: Int { index }
}
