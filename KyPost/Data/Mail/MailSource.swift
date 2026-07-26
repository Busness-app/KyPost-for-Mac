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
    func send(email: OutgoingEmail) async throws
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
    /// The relay has no endpoint for this operation (e.g. server-side search).
    case unsupported
    case invalidServerURL
    /// Relay 409 + clientSideNeeded: a client-protected account asked the
    /// server to sign or encrypt and it refused rather than silently sending
    /// in the clear.
    case clientSideNeeded
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

    static func from(_ error: Error) -> MailOutcome {
        switch error {
        case NetworkError.unauthorized:
            .unauthorized
        case MailSourceError.notPaired:
            .notPaired
        case MailSourceError.clientSideNeeded:
            .clientSideNeeded
        default:
            .failure("\(error)")
        }
    }
}
