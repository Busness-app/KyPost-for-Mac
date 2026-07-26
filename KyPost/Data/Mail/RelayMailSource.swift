//
//  RelayMailSource.swift
//  KyPost
//
//  MailSource backed by the relay endpoints, matching the Android reference
//  RelayMailSource.kt / RelayModels.kt (Mobile_Mail_Relay.md) and verified
//  against the live backend 2026-07-10. Pairing auth (deviceId/deviceSecret)
//  travels as headers (RelayAuth.headerFields), not query params:
//    GET  /api/inbox?limit&mailbox&since
//    GET  /api/inbox/folders
//    POST /api/mail/send
//  Binding contract: send body uses comma-joined recipient strings plus a
//  "mode" field; /api/inbox returns emails grouped by tab.
//

import Foundation

// MARK: - DTOs (match Mobile_Mail_Relay.md JSON exactly, like Android RelayModels.kt)

/// Some deployments emit `cursor` as a bare JSON number rather than a quoted
/// string; decode either shape (Android FlexibleCursorSerializer).
struct FlexibleCursor: Decodable, Equatable, Sendable {
    var value: String

    init(_ value: String) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int.self) {
            value = String(int)
        } else if let double = try? container.decode(Double.self) {
            value = String(double)
        } else {
            value = ""
        }
    }
}

struct RelayEmailDTO: Decodable, Equatable, Sendable {
    var messageId: String
    /// Single display string, e.g. "Ada Lovelace <ada@example.com>".
    var sender: String?
    var sentTo: String?
    var cc: String?
    var bcc: String?
    var subject: String?
    /// Nil (not "") on delta "updated" entries whose body was omitted.
    var body: String?
    var label: String?
    /// "unread" unless the server says otherwise.
    var status: String?
    /// ISO-8601 timestamp.
    var atUtc: String?
    /// "new" or "updated"; only present when the response has delta=true.
    var changeType: String?
    /// OpenPGP state, all omitempty server-side — absent means "no OpenPGP
    /// content", so these defaults are the contract, not an unknown state.
    /// See kypost-server/docs/E2E_PGP.md.
    var pgpEncrypted: Bool?
    var pgpSigned: Bool?
    var pgpVerified: Bool?
    var pgpSignerFingerprint: String?
    var pgpDecryptError: String?

    func toDomain(folder: String, tab: String) -> Email {
        let (name, address) = Self.splitSender(sender ?? "")
        let keyword = (label?.isEmpty == false ? label : tab) ?? tab
        return Email(
            serverId: messageId,
            folder: folder,
            senderName: name,
            senderEmail: address,
            subject: subject ?? "",
            body: body ?? "",
            sentTo: sentTo ?? "",
            cc: cc ?? "",
            keywords: keyword.isEmpty ? [] : [keyword],
            receivedAt: Self.parseUtc(atUtc) ?? Date(),
            read: (status ?? "unread").lowercased() != "unread",
            starred: false,
            pgpEncrypted: pgpEncrypted ?? false,
            pgpSigned: pgpSigned ?? false,
            pgpVerified: pgpVerified ?? false,
            pgpSignerFingerprint: pgpSignerFingerprint ?? "",
            pgpDecryptError: pgpDecryptError ?? ""
        )
    }

    /// Splits "Name <addr@host>" into display name and address; a bare
    /// address fills both fields.
    private static func splitSender(_ sender: String) -> (name: String, email: String) {
        let trimmed = sender.trimmingCharacters(in: .whitespaces)
        if let open = trimmed.lastIndex(of: "<"),
           let close = trimmed.lastIndex(of: ">"),
           open < close {
            let name = String(trimmed[..<open])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let email = String(trimmed[trimmed.index(after: open)..<close])
                .trimmingCharacters(in: .whitespaces)
            return (name.isEmpty ? email : name, email)
        }
        if trimmed.contains("@") {
            return (trimmed, trimmed)
        }
        return (trimmed, "")
    }

    private static func parseUtc(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: value) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value)
    }
}

struct RelayInboxResponse: Decodable, Sendable {
    var tabs: [String]?
    var byTab: [String: [RelayEmailDTO]]?
    var cursor: FlexibleCursor?
    var delta: Bool?
    var removed: [String]?

    /// Flattens the per-tab groups; each email keeps its tab as a keyword.
    /// Sorted newest first — the per-tab dictionary has no stable iteration
    /// order, and EmailDAO.getFolder reads the cache in the same order.
    func allEmails(folder: String) -> [Email] {
        (byTab ?? [:])
            .flatMap { tab, emails in
                emails.map { $0.toDomain(folder: folder, tab: tab) }
            }
            .sorted { $0.receivedAt > $1.receivedAt }
    }
}

struct RelayFolderDTO: Decodable, Equatable, Sendable {
    var path: String
    var deletable: Bool?
}

struct RelayFolderListResponse: Decodable, Sendable {
    var parent: String?
    var folders: [RelayFolderDTO]?
}

struct RelaySendResponse: Decodable, Sendable {
    var ok: Bool?
    var sentSaved: Bool?
    var warning: String?
}

/// Bulk action body (Mobile_Mail_Relay.md /api/inbox/actions).
struct RelayActionRequest: Encodable, Equatable, Sendable {
    var action: String
    var messageIds: [String]
    var mailbox: String
    /// Only "move" takes a target; JSONEncoder drops it when nil.
    var targetMailbox: String? = nil
}

struct RelayActionResponse: Decodable, Sendable {
    var ok: Bool?
}

/// Attachment metadata from GET /api/mail/attachments.
struct RelayAttachmentDTO: Decodable, Equatable, Sendable {
    var index: Int
    var name: String?
    var mimeType: String?
    var size: Int?

    func toDomain() -> EmailAttachment {
        EmailAttachment(
            index: index,
            name: name?.isEmpty == false ? name! : "attachment",
            mimeType: mimeType ?? "application/octet-stream",
            size: size ?? 0
        )
    }
}

struct RelayAttachmentListResponse: Decodable, Sendable {
    var ok: Bool?
    var attachments: [RelayAttachmentDTO]?
}

/// Outgoing attachment: base64 in the send/draft JSON (Mobile_Mail_Relay.md).
nonisolated struct RelaySendAttachmentDTO: Encodable, Equatable, Sendable {
    var name: String
    var mimeType: String
    var dataBase64: String

    init(from attachment: OutgoingAttachment) {
        name = attachment.name
        mimeType = attachment.mimeType
        dataBase64 = attachment.data.base64EncodedString()
    }
}

/// Send body with comma-joined recipients (Mobile_Mail_Relay.md Part 6) —
/// differs from contact sync's array-of-objects shape.
struct RelaySendRequest: Encodable, Equatable, Sendable {
    var to: String
    var cc: String
    var bcc: String
    var subject: String
    var body: String
    var mode: String
    /// Omitted from the JSON entirely when there are no attachments.
    var attachments: [RelaySendAttachmentDTO]?

    init(from email: OutgoingEmail) {
        to = email.to.joined(separator: ", ")
        cc = email.cc.joined(separator: ", ")
        bcc = email.bcc.joined(separator: ", ")
        subject = email.subject
        body = email.body
        mode = email.mode
        attachments = email.attachments.isEmpty
            ? nil
            : email.attachments.map(RelaySendAttachmentDTO.init)
    }
}

// MARK: - Source

final class RelayMailSource: MailSource {
    private let httpClient: HTTPClient
    private let serverUrl: String
    private let auth: RelayAuth

    init(httpClient: HTTPClient, serverUrl: String, auth: RelayAuth) {
        self.httpClient = httpClient
        self.serverUrl = serverUrl
        self.auth = auth
    }

    func listFolders(parent: String?) async throws -> [MailFolder] {
        var query: [URLQueryItem] = []
        if let parent, !parent.isEmpty {
            query.append(URLQueryItem(name: "parent", value: parent))
        }
        let response = try await httpClient.get(
            RelayFolderListResponse.self,
            url: try endpoint("api/inbox/folders"),
            query: query,
            headers: auth.headerFields
        )
        return (response.folders ?? []).map { MailFolder(name: $0.path) }
    }

    func fetchEmails(folder: String, from: Int, to: Int) async throws -> [Email] {
        // ponytail: since=0 forces a full snapshot on every fetch. Cursor
        // persistence + delta merging (Android MailCursorStore, Part 5) is v2;
        // full snapshots pair with MailRepository.replaceFolderSnapshot.
        let response = try await httpClient.get(
            RelayInboxResponse.self,
            url: try endpoint("api/inbox"),
            query: [
                URLQueryItem(name: "limit", value: String(max(to, 1))),
                URLQueryItem(name: "mailbox", value: folder),
                URLQueryItem(name: "since", value: "0"),
            ],
            headers: auth.headerFields
        )
        return response.allEmails(folder: folder)
    }

    func search(folder: String, query: String) async throws -> [String] {
        // The relay has no search endpoint (Android searches its local cache);
        // inbox search runs against the EmailDAO cache instead.
        throw MailSourceError.unsupported
    }

    func setKeywords(folder: String, messageId: String, keywords: [String]) async throws {
        // Relay tabs are server-assigned; there is no relay endpoint for
        // client-side keyword edits.
        throw MailSourceError.unsupported
    }

    func move(messageIds: [String], from mailbox: String, to targetMailbox: String) async throws {
        try await performAction("move", messageIds: messageIds, mailbox: mailbox, targetMailbox: targetMailbox)
    }

    func delete(messageIds: [String], mailbox: String) async throws {
        try await performAction("delete", messageIds: messageIds, mailbox: mailbox)
    }

    func archive(messageIds: [String], mailbox: String) async throws {
        try await performAction("archive", messageIds: messageIds, mailbox: mailbox)
    }

    func markSpam(messageIds: [String], mailbox: String) async throws {
        try await performAction("spam", messageIds: messageIds, mailbox: mailbox)
    }

    func markRead(messageIds: [String], mailbox: String) async throws {
        try await performAction("read", messageIds: messageIds, mailbox: mailbox)
    }

    /// POST /api/inbox/actions — the bulk verbs share one body shape
    /// (Mobile_Mail_Relay.md; only "move" carries targetMailbox).
    private func performAction(
        _ action: String,
        messageIds: [String],
        mailbox: String,
        targetMailbox: String? = nil
    ) async throws {
        _ = try await httpClient.post(
            RelayActionResponse.self,
            url: try endpoint("api/inbox/actions"),
            headers: auth.headerFields,
            jsonBody: RelayActionRequest(
                action: action,
                messageIds: messageIds,
                mailbox: mailbox,
                targetMailbox: targetMailbox
            )
        )
    }

    func listAttachments(folder: String, messageId: String) async throws -> [EmailAttachment] {
        let response = try await httpClient.get(
            RelayAttachmentListResponse.self,
            url: try endpoint("api/mail/attachments"),
            query: [
                URLQueryItem(name: "mailbox", value: folder),
                URLQueryItem(name: "messageId", value: messageId),
            ],
            headers: auth.headerFields
        )
        return (response.attachments ?? []).map { $0.toDomain() }
    }

    func downloadAttachment(folder: String, messageId: String, index: Int) async throws -> Data {
        try await httpClient.getData(
            url: try endpoint("api/mail/attachment"),
            query: [
                URLQueryItem(name: "mailbox", value: folder),
                URLQueryItem(name: "messageId", value: messageId),
                URLQueryItem(name: "index", value: String(index)),
            ],
            headers: auth.headerFields
        )
    }

    func send(email: OutgoingEmail) async throws {
        _ = try await httpClient.post(
            RelaySendResponse.self,
            url: try endpoint("api/mail/send"),
            headers: auth.headerFields,
            jsonBody: RelaySendRequest(from: email)
        )
    }

    // MARK: - Private

    private func endpoint(_ path: String) throws -> URL {
        guard let url = URL(string: serverUrl) else {
            throw MailSourceError.invalidServerURL
        }
        return url.appending(path: path)
    }
}
