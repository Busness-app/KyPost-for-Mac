//
//  EmailBodyRendering.swift
//  KyPost
//
//  How a message body becomes something to render. Swift port of
//  kypost-android's emailBodyToHtml / isPlainTextBody / bodyLooksLikeHtml.
//
//  Pure functions so the decisions are testable without SwiftUI or WebKit,
//  and so the reader does not re-derive them inline.
//

import Foundation

/// The relay's `bodyMode`, normalised. "" means the server did not say —
/// distinct from either value, and the only case where sniffing is allowed.
nonisolated func normalizedBodyMode(_ mode: String) -> String {
    let lowered = mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return (lowered == "html" || lowered == "plain") ? lowered : ""
}

/// Structural HTML markup, as opposed to a plain-text body that happens to
/// mention a `<` character.
nonisolated func bodyLooksLikeHTML(_ body: String) -> Bool {
    body.range(
        of: "<(html|head|body|div|p|br|table|tr|td|a|img|span|ul|ol|li|h[1-6])[\\s>/]",
        options: [.regularExpression, .caseInsensitive]
    ) != nil
}

/// Markdown that a relay mislabelled as HTML. Rendering it through the
/// WebView shows the raw `#` and `[]()` syntax; the native path wraps it as
/// the text it is.
nonisolated func bodyLooksLikeMarkdown(_ body: String) -> Bool {
    body.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
        let text = String(line)
        if text.range(of: "^\\s{0,3}#{1,6}\\s+.+", options: .regularExpression) != nil {
            return true
        }
        if text.range(of: "\\[[^\\]]+\\]\\(https?://[^)]+\\)", options: .regularExpression) != nil {
            return true
        }
        return text.trimmingCharacters(in: .whitespaces).hasPrefix("```")
    }
}

/// Whether to render natively (wrapping `Text`) rather than in the WebView.
///
/// A declared "plain" is taken at its word — that is the whole point of
/// carrying `bodyMode`. A declared "html" is still checked against the body,
/// deliberately: some relay and cache rows label Markdown or plain content as
/// HTML, and honouring that blindly puts unwrapped raw text behind a
/// horizontal scrollbar. Real markup stays in the WebView either way.
nonisolated func isPlainTextBody(_ body: String, mode: String) -> Bool {
    switch normalizedBodyMode(mode) {
    case "plain":
        return true
    default:
        // Covers declared "html" and the unknown/absent case alike.
        return !bodyLooksLikeHTML(body) || bodyLooksLikeMarkdown(body)
    }
}

/// The body as HTML, for the WebView and for quoting.
///
/// A declared mode is honoured without inspecting the body: sniffing a body
/// the server has already described is how a plain-text message containing
/// `<not a tag>` ends up rendered as markup, and how a real HTML message that
/// happens to open with text ends up escaped.
nonisolated func emailBodyToHTML(_ body: String, mode: String) -> String {
    switch normalizedBodyMode(mode) {
    case "html":
        return body
    case "plain":
        return plainTextBlock(body)
    default:
        return bodyLooksLikeHTML(body) ? body : plainTextBlock(body)
    }
}

private nonisolated func plainTextBlock(_ text: String) -> String {
    "<div class=\"kypost-plain-text\">\(escapeHTMLText(text))</div>"
}

/// Escapes text for insertion into HTML. `&` first, or the escapes introduced
/// by the later replacements get escaped again.
nonisolated func escapeHTMLText(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&#39;")
}
