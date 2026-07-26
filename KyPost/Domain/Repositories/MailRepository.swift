//
//  MailRepository.swift
//  KyPost
//
//  Mail access through the paired relay, keeping the local cache (EmailDAO)
//  in sync so the inbox works offline.
//

import Foundation

final class MailRepository {
    private let securePairingStore: SecurePairingStore
    private let emailDAO: EmailDAO
    private let httpClient: HTTPClient

    init(
        securePairingStore: SecurePairingStore,
        emailDAO: EmailDAO,
        httpClient: HTTPClient
    ) {
        self.securePairingStore = securePairingStore
        self.emailDAO = emailDAO
        self.httpClient = httpClient
    }

    /// The relay source; requires a stored pairing.
    func makeSource() throws -> any MailSource {
        guard let pairing = try securePairingStore.loadPairing() else {
            throw MailSourceError.notPaired
        }
        return RelayMailSource(
            httpClient: httpClient,
            serverUrl: pairing.srv,
            auth: RelayAuth(pairing: pairing)
        )
    }

    func listFolders(parent: String? = nil) async throws -> [MailFolder] {
        try await makeSource().listFolders(parent: parent)
    }

    /// Fetches a folder from the server and replaces the cached snapshot.
    @discardableResult
    func refreshFolder(_ folder: String, from: Int = 0, to: Int = 50) async throws -> [Email] {
        let emails = try await makeSource().fetchEmails(folder: folder, from: from, to: to)
        try await emailDAO.replaceFolderSnapshot(folder: folder, emails: emails)
        return emails
    }

    /// Cached emails for offline/instant display.
    func cachedFolder(_ folder: String, limit: Int = 50, offset: Int = 0) async throws -> [Email] {
        try await emailDAO.getFolder(folder: folder, limit: limit, offset: offset)
    }

    /// Search runs against the local cache (the relay has no search endpoint).
    func search(folder: String, query: String) async throws -> [Email] {
        try await emailDAO.search(folder: folder, query: query)
    }

    /// Moves messages between folders via the relay's bulk-actions endpoint.
    func move(messageIds: [String], from mailbox: String, to targetMailbox: String) async throws {
        try await makeSource().move(messageIds: messageIds, from: mailbox, to: targetMailbox)
    }

    /// Deletes messages via the relay: moved to Trash, or expunged when
    /// `mailbox` is already Trash.
    func delete(messageIds: [String], from mailbox: String) async throws {
        try await makeSource().delete(messageIds: messageIds, mailbox: mailbox)
    }

    /// Archives messages via the relay (moved to the Archive folder).
    func archive(messageIds: [String], from mailbox: String) async throws {
        try await makeSource().archive(messageIds: messageIds, mailbox: mailbox)
    }

    /// Marks messages as junk via the relay (moved to Junk).
    func markSpam(messageIds: [String], from mailbox: String) async throws {
        try await makeSource().markSpam(messageIds: messageIds, mailbox: mailbox)
    }

    /// Attachment metadata for one cached email (lazy, on open).
    func listAttachments(folder: String, messageId: String) async throws -> [EmailAttachment] {
        try await makeSource().listAttachments(folder: folder, messageId: messageId)
    }

    /// Raw bytes of one attachment.
    func downloadAttachment(folder: String, messageId: String, index: Int) async throws -> Data {
        try await makeSource().downloadAttachment(folder: folder, messageId: messageId, index: index)
    }

    /// Updates the local read flag and (when marking read from a known
    /// mailbox) syncs it to the relay so other devices see it — the relay has
    /// a "read" action but no "unread" counterpart.
    func markRead(serverId: String, folder: String? = nil, read: Bool = true) async throws {
        try await emailDAO.updateEmail(serverId: serverId, read: read)
        if read, let folder {
            try await makeSource().markRead(messageIds: [serverId], mailbox: folder)
        }
    }

    func send(_ email: OutgoingEmail) async -> MailOutcome {
        do {
            let warning = try await makeSource().send(email: email)
            return warning.isEmpty ? .success : .sentWithWarning(warning)
        } catch {
            return MailOutcome.from(error)
        }
    }

    /// Saves a draft on the server so the webmail handoff has something to
    /// open. Same failure mapping as `send`.
    func saveDraft(_ email: OutgoingEmail) async -> MailOutcome {
        do {
            try await makeSource().saveDraft(email: email)
            return .success
        } catch {
            return MailOutcome.from(error)
        }
    }

    /// The paired server's base URL, for building webmail links. Nil when
    /// unpaired, so callers show no link rather than a dead one.
    var pairedServerUrl: String? {
        guard let pairing = try? securePairingStore.loadPairing(),
              !pairing.srv.isEmpty
        else { return nil }
        return pairing.srv
    }
}
