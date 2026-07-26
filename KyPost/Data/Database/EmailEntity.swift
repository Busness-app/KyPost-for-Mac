//
//  EmailEntity.swift
//  KyPost
//
//  SwiftData entity for the emails table (spec §8).
//

import Foundation
import SwiftData

@Model
final class EmailEntity {
    /// Relay message id.
    @Attribute(.unique) var serverId: String
    var folder: String
    var senderName: String
    var senderEmail: String
    var subject: String
    var body: String
    /// Raw To/Cc header strings (see Email.sentTo/cc); default "" keeps
    /// stores created before these columns migrating cleanly.
    var sentTo: String = ""
    var cc: String = ""
    var keywords: [String]
    var receivedAt: Date
    var read: Bool
    var starred: Bool
    /// Relay OpenPGP state; defaults keep stores created before these columns
    /// migrating cleanly (same lightweight pattern as sentTo/cc above).
    var pgpEncrypted: Bool = false
    var pgpSigned: Bool = false
    var pgpVerified: Bool = false
    var pgpSignerFingerprint: String = ""
    var pgpDecryptError: String = ""
    var createdAt: Date

    init(
        serverId: String,
        folder: String,
        senderName: String,
        senderEmail: String,
        subject: String,
        body: String,
        sentTo: String = "",
        cc: String = "",
        keywords: [String],
        receivedAt: Date,
        read: Bool,
        starred: Bool,
        pgpEncrypted: Bool = false,
        pgpSigned: Bool = false,
        pgpVerified: Bool = false,
        pgpSignerFingerprint: String = "",
        pgpDecryptError: String = "",
        createdAt: Date = Date()
    ) {
        self.serverId = serverId
        self.folder = folder
        self.senderName = senderName
        self.senderEmail = senderEmail
        self.subject = subject
        self.body = body
        self.sentTo = sentTo
        self.cc = cc
        self.keywords = keywords
        self.receivedAt = receivedAt
        self.read = read
        self.starred = starred
        self.pgpEncrypted = pgpEncrypted
        self.pgpSigned = pgpSigned
        self.pgpVerified = pgpVerified
        self.pgpSignerFingerprint = pgpSignerFingerprint
        self.pgpDecryptError = pgpDecryptError
        self.createdAt = createdAt
    }
}

// MARK: - Mapping (EmailMapper equivalent)

extension EmailEntity {
    convenience init(from email: Email) {
        self.init(
            serverId: email.serverId,
            folder: email.folder,
            senderName: email.senderName,
            senderEmail: email.senderEmail,
            subject: email.subject,
            body: email.body,
            sentTo: email.sentTo,
            cc: email.cc,
            keywords: email.keywords.sorted(),
            receivedAt: email.receivedAt,
            read: email.read,
            starred: email.starred,
            pgpEncrypted: email.pgpEncrypted,
            pgpSigned: email.pgpSigned,
            pgpVerified: email.pgpVerified,
            pgpSignerFingerprint: email.pgpSignerFingerprint,
            pgpDecryptError: email.pgpDecryptError
        )
    }

    var toDomain: Email {
        Email(
            serverId: serverId,
            folder: folder,
            senderName: senderName,
            senderEmail: senderEmail,
            subject: subject,
            body: body,
            sentTo: sentTo,
            cc: cc,
            keywords: Set(keywords),
            receivedAt: receivedAt,
            read: read,
            starred: starred,
            pgpEncrypted: pgpEncrypted,
            pgpSigned: pgpSigned,
            pgpVerified: pgpVerified,
            pgpSignerFingerprint: pgpSignerFingerprint,
            pgpDecryptError: pgpDecryptError
        )
    }
}
