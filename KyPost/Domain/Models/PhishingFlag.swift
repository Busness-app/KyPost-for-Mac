//
//  PhishingFlag.swift
//  KyPost
//
//  The IMAP keyword the server sets on inbound mail that impersonates KyPost
//  itself. Swift port of kypost-android's mail/PhishingFlag.kt.
//

import Foundation

/// `$Phishing` is the reserved RFC 8621 keyword, so other mail clients
/// understand it too. The message is flagged in place: it stays in the inbox,
/// stays unread, and keeps its body. Nothing here moves or hides mail.
///
/// Mirrored as a literal rather than shared, because the other clients are
/// Kotlin, TypeScript and QML and there is no cross-repo artifact to share it
/// through. The contract is the keyword string itself.
let phishingKeyword = "$Phishing"

/// Whether a message carries the phishing flag.
///
/// Case-insensitive because IMAP keywords are: a server may echo back
/// `$phishing` for a keyword the poller set as `$Phishing`, and a
/// case-sensitive check would silently drop the warning on precisely the mail
/// it exists for. Trimmed for the same reason.
///
/// Exact match, not a prefix: `$PhishingReport` is a different keyword.
nonisolated func isFlaggedPhishing(_ keywords: some Sequence<String>) -> Bool {
    keywords.contains {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
            .compare(phishingKeyword, options: .caseInsensitive) == .orderedSame
    }
}

/// Whether a keyword is an IMAP system flag rather than a user-facing label.
///
/// RFC 8621 reserves the `$`-prefixed namespace for protocol keywords
/// (`$Phishing`, `$Junk`, `$Forwarded`…). They drive behaviour — the phishing
/// warning reads one — but they are not labels the user chose, so they do not
/// belong in the tab strip or on a row as a chip.
///
/// Deliberate divergence from Android, whose `KeywordTabs.buildTabs` does not
/// filter them and would show a `$Phishing` tab.
nonisolated func isSystemKeyword(_ keyword: String) -> Bool {
    keyword.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("$")
}
