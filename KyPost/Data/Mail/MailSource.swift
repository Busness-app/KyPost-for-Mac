//
//  MailSource.swift
//  KyPost
//
//  Abstraction over the mail backend. Relay is the only transport
//  (IMAP was dropped); the protocol remains so the transport stays swappable.
//

import Foundation

/// Message ids are Strings (`Email.serverId`) — relay ids.
protocol MailSource: Sendable {
    /// Lists folders; `parent` scopes to that folder's children (nil = top level).
    func listFolders(parent: String?) async throws -> [MailFolder]
    func fetchEmails(folder: String, from: Int, to: Int) async throws -> [Email]
    func search(folder: String, query: String) async throws -> [String]
    func setKeywords(folder: String, messageId: String, keywords: [String]) async throws
    func move(messageIds: [String], from mailbox: String, to targetMailbox: String) async throws
    /// Deletes messages. The relay moves them to Trash, or expunges them
    /// permanently when `mailbox` is already Trash (server.go ApplyInboxAction).
    func delete(messageIds: [String], mailbox: String) async throws
    /// Moves messages to the Archive folder (Android MailAction.ARCHIVE).
    func archive(messageIds: [String], mailbox: String) async throws
    /// Moves messages to Junk (Android MailAction.SPAM).
    func markSpam(messageIds: [String], mailbox: String) async throws
    /// Flags messages read on the server so the state syncs across devices.
    func markRead(messageIds: [String], mailbox: String) async throws
    /// Attachment metadata for one message (fetched lazily on open; the
    /// inbox listing carries no attachment info).
    func listAttachments(folder: String, messageId: String) async throws -> [EmailAttachment]
    /// One attachment's raw bytes, by its index from `listAttachments`.
    func downloadAttachment(folder: String, messageId: String, index: Int) async throws -> Data
    /// Sends a message and returns the relay's `warning` — empty on a clean
    /// send, non-empty on a *partial* problem (the Sent copy failed to save,
    /// and/or some pickup links failed to deliver). A warning still means the
    /// message went out: never retry on one, it would duplicate.
    @discardableResult
    func send(email: OutgoingEmail) async throws -> String
    /// Saves a draft server-side (POST /api/mail/draft). Same body shape as
    /// `send` minus the PGP flags; the response is `{"ok": true}` and every
    /// failure is a plain-text error. The client-custody webmail handoff
    /// depends on this call.
    func saveDraft(email: OutgoingEmail) async throws
}

extension MailSource {
    /// Top-level folders.
    func listFolders() async throws -> [MailFolder] {
        try await listFolders(parent: nil)
    }
}

/// Mail-layer failures that aren't plain network errors.
enum MailSourceError: Error, Equatable {
    /// No pairing stored — the user must pair the device first.
    case notPaired
    /// The pairing exists but its secret is unreadable right now: the
    /// credential gate is on and the app is locked. Not an error state —
    /// background work retries after the next unlock, like `notPaired`.
    case credentialUnavailable
    /// The relay has no endpoint for this operation (e.g. server-side search).
    case unsupported
    case invalidServerURL
    /// Relay 409 + clientSideNeeded: a client-protected account asked the
    /// server to sign or encrypt and it refused rather than silently sending
    /// in the clear.
    case clientSideNeeded
    /// Relay 409 + keylessRecipients: at least one recipient has no usable
    /// key. **Nothing was delivered** — the refusal happens before any SMTP.
    /// Re-sending the identical request with `allowPickupFallback: true` is
    /// safe and cannot duplicate. `pickupFallbackAvailable` is false when the
    /// server has one-time links turned off, in which case there is nothing to
    /// offer the user.
    case keylessRecipients(addresses: [String], pickupFallbackAvailable: Bool)
}

/// User-facing result of a mail operation (spec §11 relay response mapping).
enum MailOutcome: Equatable, Sendable {
    case success
    /// Recipients/fields invalid before any network call.
    case invalid(String)
    /// Credentials rejected — re-pair the device.
    case unauthorized
    case notPaired
    case failure(String)
    /// The account's PGP key is end-to-end protected; the server will not sign
    /// or encrypt on its behalf and this app holds no private key.
    case clientSideNeeded
    /// Sent, but with a partial problem worth showing (Sent copy not saved,
    /// some pickup links undelivered). Not a failure; offering a retry here
    /// would duplicate the message. Treat the text as opaque human-readable
    /// prose — never pattern-match its wording.
    case sentWithWarning(String)
    /// Some recipients have no usable key and nothing was sent. Confirming
    /// mails them a one-time link and stores this message's plaintext on the
    /// server for 7 days.
    case keylessRecipients(addresses: [String], pickupFallbackAvailable: Bool)

    static func from(_ error: Error) -> MailOutcome {
        switch error {
        case NetworkError.unauthorized:
            .unauthorized
        case MailSourceError.notPaired:
            .notPaired
        case MailSourceError.clientSideNeeded:
            .clientSideNeeded
        case MailSourceError.keylessRecipients(let addresses, let pickupFallbackAvailable):
            .keylessRecipients(
                addresses: addresses,
                pickupFallbackAvailable: pickupFallbackAvailable
            )
        case let networkError as NetworkError:
            .failure(Self.message(for: networkError))
        default:
            .failure("\(error)")
        }
    }

    /// Human-readable text for the `NetworkError` cases that reach here
    /// unclaimed (401 and the two PGP 409s are already peeled off above).
    /// Without this, `.failure("\(error)")` puts the raw enum dump — e.g.
    /// "server(statusCode: 404)" — straight in front of the user; the server
    /// side of this feature isn't merged yet, so a 404 from the draft-save
    /// call is exactly what the first tester hits.
    ///
    /// Internal rather than private because the networking clients need it
    /// too: they each ended in `.failure("\(error)")`, and string
    /// interpolation resolves through `String(describing:)`, which never
    /// consults `LocalizedError`. That printed "certificateMismatch" where a
    /// warning that the connection may be intercepted was intended.
    static func message(for error: NetworkError) -> String {
        switch error {
        case .invalidURL: "This server's address looks wrong."
        case .unauthorized: "Not authorized — re-pair the device or check credentials."
        case .conflict: "The server rejected this request."
        case .rateLimited: "Too many attempts — wait a moment and try again."
        case .serviceUnavailable: "The server is temporarily unavailable."
        case .certificateMismatch: error.errorDescription
            ?? "The server's security certificate changed — re-pair the device."
        case .server(let statusCode): "The server returned an error (status \(statusCode))."
        case .transport(let description): description
        case .decoding: "The server sent a response this app couldn't read."
        }
    }
}
