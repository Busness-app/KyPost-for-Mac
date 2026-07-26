//
//  PgpMessageState.swift
//  KyPost
//
//  What this app can actually do with a message's OpenPGP content.
//
//  Pure functions of the relay's pgp* fields, so the decisions are testable
//  without SwiftUI or a stubbed network and no view re-derives them. Ported
//  from kypost-android's pgp/PgpMessageState.kt and pgp/WebmailDeepLink.kt.
//
//  This app holds no PGP private key and will not gain one — see
//  kypost-server/docs/E2E_PGP.md. Mobile and desktop-native clients implement
//  the degradation, never the crypto.
//

import Foundation

nonisolated enum PgpMessageState: Equatable, Sendable {
    /// No OpenPGP content: render normally.
    case none

    /// Encrypted, and the server deliberately did not decrypt it because the
    /// account's key is end-to-end protected. There is no body and this app
    /// holds no private key, so the only route to the content is webmail.
    case clientProtected

    /// Encrypted, and the server tried to decrypt and failed. There is a real
    /// error to show.
    case decryptFailed

    /// Encrypted, and the server decrypted it for us. Worth surfacing rather
    /// than rendering silently: the user should be able to tell that the
    /// server read their mail.
    case decryptedByServer
}

/// The ordering matters. A non-blank `pgpDecryptError` is checked before the
/// body, because the server populates the error and leaves the body empty —
/// reading that as `.clientProtected` would tell the user to go to webmail for
/// a message that will fail there too, for a reason we were already told.
nonisolated func pgpMessageState(
    pgpEncrypted: Bool,
    pgpDecryptError: String,
    body: String?
) -> PgpMessageState {
    guard pgpEncrypted else { return .none }
    if !pgpDecryptError.isBlank { return .decryptFailed }
    if let body, !body.isBlank { return .decryptedByServer }
    return .clientProtected
}

/// SF Symbol for an inbox row, or nil for no marker.
///
/// Only the two states that yield no readable content are marked.
/// `.decryptedByServer` is deliberately unmarked: the row opens and reads
/// normally, so a marker there would sit on most rows of a server-mode mailbox
/// carrying nothing the user can act on — and the detail view already discloses
/// that the server decrypted it.
nonisolated func pgpRowSymbol(_ state: PgpMessageState) -> String? {
    switch state {
    case .clientProtected: "lock.fill"
    case .decryptFailed: "exclamationmark.triangle.fill"
    case .none, .decryptedByServer: nil
    }
}

/// Spelled-out row label for VoiceOver, or nil when the row carries no marker.
nonisolated func pgpRowAccessibilityLabel(state: PgpMessageState, subject: String) -> String? {
    switch state {
    case .clientProtected: "Encrypted, can't be read in this app: \(subject)"
    case .decryptFailed: "Encrypted, couldn't be decrypted: \(subject)"
    case .none, .decryptedByServer: nil
    }
}

/// Whether to show a signature verdict at all.
///
/// True only for `.decryptedByServer`. For a client-protected message the
/// server never saw the plaintext, so its `pgpSigned`/`pgpVerified` values are
/// not a verdict about content anyone verified — showing "signature not
/// verified" would assert something we have no basis for. The web client can
/// fall back to a local decrypt for this (frontend ReadPage.tsx); this app
/// cannot, and never will.
nonisolated func showsSignaturePill(state: PgpMessageState, signed: Bool) -> Bool {
    state == .decryptedByServer && signed
}

/// Builds the webmail URL that opens one specific message — the same `/read`
/// route a web push click uses, so no server change backs it.
///
/// INBOX is sent as an absent `mailbox` param rather than the literal string,
/// matching the links the web app builds for itself. Returns nil when
/// `serverUrl` isn't a usable absolute URL, which callers render as "no button"
/// rather than a dead one.
nonisolated func webmailMessageURL(serverUrl: String, mailbox: String, messageId: String) -> URL? {
    guard !messageId.isBlank else { return nil }
    let trimmed = serverUrl.trimmingCharacters(in: .whitespaces)
    let base = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
    guard var components = URLComponents(string: base),
          components.scheme != nil,
          components.host != nil
    else { return nil }

    components.path += "/read"

    var items: [URLQueryItem] = []
    let mailbox = mailbox.trimmingCharacters(in: .whitespaces)
    if !mailbox.isEmpty, mailbox.caseInsensitiveCompare(StandardFolder.inbox) != .orderedSame {
        items.append(URLQueryItem(name: "mailbox", value: mailbox))
    }
    items.append(URLQueryItem(name: "message", value: messageId))
    components.queryItems = items

    return components.url
}

private extension String {
    var isBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
