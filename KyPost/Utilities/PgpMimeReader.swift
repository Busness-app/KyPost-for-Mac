//
//  PgpMimeReader.swift
//  KyPost
//
//  Parses decrypted PGP/MIME bytes into the parts the reader renders. Swift
//  port of kypost-android's pgp/PgpMimeReader.kt.
//
//  Android leaned on `angus.mail`. Foundation has no MIME parser and this app
//  has one external dependency already, so the subset PGP/MIME actually uses is
//  implemented here: headers, multipart boundaries, base64 and
//  quoted-printable, and RFC 2047 encoded-words in the protected subject.
//
//  Returns nil rather than throwing on anything unparseable. The caller renders
//  an exit-table row; putting unparsed bytes into a WebView is not a
//  degradation this accepts.
//

import Foundation

nonisolated enum PgpMimeReader {

    /// Guards against a pathological nesting depth in hostile input. Real
    /// PGP/MIME is two or three levels; this is only here so a crafted message
    /// cannot recurse until the stack gives out.
    private static let maxDepth = 12

    static func read(_ mime: Data) -> DecryptedBody? {
        let part = parse(mime)

        var html: String?
        var plain: String?
        collect(part, depth: 0, html: &html, plain: &plain)

        // A body with no recognised Content-Type is RFC 2045's default of
        // text/plain. An empty one there came from the default rather than
        // from anything parsed, so it is treated as absent — whereas an empty
        // body under a Content-Type header that *was* present is real content
        // ("no body, attachment only" is a legitimate message).
        if part.contentType == nil, plain?.isEmpty == true, html == nil {
            plain = nil
        }

        guard html != nil || plain != nil else { return nil }

        return DecryptedBody(
            html: html,
            plain: plain,
            bodyMode: html != nil ? "html" : "plain",
            protectedSubject: part.headerValue("subject")
                .map(decodeEncodedWords)
                .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        )
    }

    // MARK: - Walking

    /// Fills the html and plain slots from a part tree.
    ///
    /// A blank part is real content — a multipart whose only text part is
    /// empty must yield `""` rather than nil. But it must not *lock* the slot:
    /// a later sibling with actual content has to win, or the message renders
    /// blank with no error and nothing to explain it.
    private static func collect(
        _ part: Part,
        depth: Int,
        html: inout String?,
        plain: inout String?
    ) {
        guard depth <= maxDepth else { return }

        if !part.children.isEmpty {
            for child in part.children {
                collect(child, depth: depth + 1, html: &html, plain: &plain)
            }
            return
        }

        let type = part.mimeType
        // An attachment is not the body, however textual it is.
        guard !part.isAttachment else { return }

        if type == "text/html" {
            if html == nil || html?.isEmpty == true { html = part.text }
        } else if type == "text/plain" || part.contentType == nil {
            if plain == nil || plain?.isEmpty == true { plain = part.text }
        }
    }

    // MARK: - Parsing

    private struct Part {
        var headers: [(name: String, value: String)] = []
        var body: Data = Data()
        var children: [Part] = []
        var contentType: String?

        func headerValue(_ name: String) -> String? {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        var mimeType: String {
            guard let contentType else { return "text/plain" }
            return contentType
                .split(separator: ";", maxSplits: 1)
                .first
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? "text/plain"
        }

        var isAttachment: Bool {
            guard let disposition = headerValue("content-disposition") else { return false }
            return disposition.lowercased().hasPrefix("attachment")
        }

        /// The decoded, charset-interpreted text of a leaf part.
        var text: String {
            let decoded = decodeTransfer(
                body,
                encoding: headerValue("content-transfer-encoding")?
                    .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            )
            return decodeText(decoded, charset: parameter("charset", of: contentType))
        }
    }

    private static func parse(_ data: Data) -> Part {
        var part = Part()
        let (headerBytes, bodyBytes) = splitHeaders(data)
        part.headers = parseHeaders(headerBytes)
        part.body = bodyBytes
        part.contentType = part.headerValue("content-type")

        guard part.mimeType.hasPrefix("multipart/"),
              let boundary = parameter("boundary", of: part.contentType), !boundary.isEmpty
        else { return part }

        part.children = splitMultipart(bodyBytes, boundary: boundary).map(parse)
        return part
    }

    /// Splits at the first blank line, tolerating both CRLF and bare LF —
    /// decrypted output has been through a compressor and a mail chain, and
    /// insisting on CRLF here loses real messages.
    private static func splitHeaders(_ data: Data) -> (Data, Data) {
        let bytes = [UInt8](data)
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x0A {
                // \n\n
                if index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                    return (Data(bytes[0..<index]), Data(bytes[(index + 2)...]))
                }
                // \n\r\n
                if index + 2 < bytes.count, bytes[index + 1] == 0x0D, bytes[index + 2] == 0x0A {
                    return (Data(bytes[0..<index]), Data(bytes[(index + 3)...]))
                }
            }
            index += 1
        }
        return (data, Data())
    }

    private static func parseHeaders(_ data: Data) -> [(name: String, value: String)] {
        // CRLF is normalised away *before* splitting, because in Swift "\r\n"
        // is a single Character — one grapheme cluster — so
        // `split(separator: "\n")` does not split it at all. Without this a
        // two-header block parses as one header whose value swallows every
        // line after the first, and the Content-Type ends up unrecognisable.
        let text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
        var headers: [(name: String, value: String)] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : String(rawLine)
            if line.isEmpty { continue }
            // A continuation line: folded headers belong to the previous one.
            if line.first == " " || line.first == "\t" {
                guard !headers.isEmpty else { continue }
                headers[headers.count - 1].value += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers.append((
                name: String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces),
                value: String(line[line.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
            ))
        }
        return headers
    }

    /// Splits a multipart body on its boundary.
    private static func splitMultipart(_ data: Data, boundary: String) -> [Data] {
        let delimiter = Data("--\(boundary)".utf8)
        var parts: [Data] = []
        var searchFrom = data.startIndex
        var currentStart: Int?

        while let found = data.range(of: delimiter, in: searchFrom..<data.endIndex) {
            // Only a boundary at the start of a line counts; the same bytes
            // inside a body are content.
            let atLineStart = found.lowerBound == data.startIndex
                || data[data.index(before: found.lowerBound)] == 0x0A
            if atLineStart {
                if let start = currentStart {
                    var end = found.lowerBound
                    // Drop the CRLF that belongs to the delimiter, not the part.
                    if end > start, data[data.index(before: end)] == 0x0A { end = data.index(before: end) }
                    if end > start, data[data.index(before: end)] == 0x0D { end = data.index(before: end) }
                    parts.append(data[start..<end])
                }
                // The closing delimiter is `--boundary--`.
                let after = found.upperBound
                if after < data.endIndex,
                   data[after] == 0x2D,
                   data.index(after: after) < data.endIndex,
                   data[data.index(after: after)] == 0x2D {
                    return parts
                }
                currentStart = skipToLineStart(data, from: after)
            }
            searchFrom = found.upperBound
        }

        if let start = currentStart, start < data.endIndex {
            parts.append(data[start..<data.endIndex])
        }
        return parts
    }

    private static func skipToLineStart(_ data: Data, from index: Data.Index) -> Data.Index {
        var cursor = index
        while cursor < data.endIndex, data[cursor] != 0x0A { cursor = data.index(after: cursor) }
        return cursor < data.endIndex ? data.index(after: cursor) : data.endIndex
    }

    // MARK: - Decoding

    private static func parameter(_ name: String, of headerValue: String?) -> String? {
        guard let headerValue else { return nil }
        for piece in headerValue.split(separator: ";").dropFirst() {
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[trimmed.startIndex..<equals]).trimmingCharacters(in: .whitespaces)
            guard key.caseInsensitiveCompare(name) == .orderedSame else { continue }
            var value = String(trimmed[trimmed.index(after: equals)...])
                .trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            return value
        }
        return nil
    }

    private static func decodeTransfer(_ data: Data, encoding: String) -> Data {
        switch encoding {
        case "base64":
            // Ignoring line breaks is required, not lenient: base64 in MIME is
            // wrapped at 76 columns by definition.
            let text = String(decoding: data, as: UTF8.self)
                .components(separatedBy: .whitespacesAndNewlines).joined()
            return Data(base64Encoded: text) ?? data
        case "quoted-printable":
            return decodeQuotedPrintable(data)
        default:
            return data
        }
    }

    private static func decodeQuotedPrintable(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x3D else {  // '='
                out.append(bytes[index])
                index += 1
                continue
            }
            // A soft line break: '=' at end of line means "no break here".
            if index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                index += 2
                continue
            }
            if index + 2 < bytes.count, bytes[index + 1] == 0x0D, bytes[index + 2] == 0x0A {
                index += 3
                continue
            }
            if index + 2 < bytes.count,
               let high = hexValue(bytes[index + 1]),
               let low = hexValue(bytes[index + 2]) {
                out.append(high << 4 | low)
                index += 3
                continue
            }
            // A stray '=' that decodes to nothing is kept rather than dropped.
            out.append(bytes[index])
            index += 1
        }
        return Data(out)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x41...0x46: byte - 0x41 + 10
        case 0x61...0x66: byte - 0x61 + 10
        default: nil
        }
    }

    private static func decodeText(_ data: Data, charset: String?) -> String {
        let name = (charset ?? "utf-8").lowercased()
        switch name {
        case "utf-8", "utf8", "us-ascii", "ascii", "":
            return String(decoding: data, as: UTF8.self)
        case "iso-8859-1", "latin1", "iso8859-1":
            return String(data: data, encoding: .isoLatin1)
                ?? String(decoding: data, as: UTF8.self)
        case "windows-1252", "cp1252":
            return String(data: data, encoding: .windowsCP1252)
                ?? String(decoding: data, as: UTF8.self)
        default:
            // Unknown charset: UTF-8 is the only sane guess, and its decoder
            // substitutes rather than failing, so nothing is lost outright.
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// Decodes RFC 2047 `=?charset?B?...?=` / `?Q?...?=` words.
    ///
    /// Only for the protected subject. A subject is the one header this reader
    /// surfaces, and non-ASCII subjects arrive encoded far more often than not.
    static func decodeEncodedWords(_ value: String) -> String {
        guard value.contains("=?") else { return value }
        var result = ""
        var rest = Substring(value)

        // An explicit scan rather than splitting on "?": the payload of a
        // B-encoded word ends in "=" padding, so a split-and-index approach
        // mistakes the padding for a delimiter and hands back the raw word.
        while let open = rest.range(of: "=?") {
            result += rest[rest.startIndex..<open.lowerBound]
            let after = rest[open.upperBound...]

            guard let charsetEnd = after.firstIndex(of: "?"),
                  case let afterCharset = after[after.index(after: charsetEnd)...],
                  let encodingEnd = afterCharset.firstIndex(of: "?"),
                  let close = afterCharset.range(of: "?=")
            else {
                // Not a well-formed encoded word; keep it verbatim rather than
                // dropping text the user was meant to read.
                result += rest[open.lowerBound...]
                return result
            }

            let charset = String(after[after.startIndex..<charsetEnd])
            let encoding = afterCharset[afterCharset.startIndex..<encodingEnd]
            let payload = afterCharset[afterCharset.index(after: encodingEnd)..<close.lowerBound]

            let decoded: Data? = switch encoding.first {
            case "B", "b":
                Data(base64Encoded: String(payload))
            case "Q", "q":
                // RFC 2047 Q-encoding differs from quoted-printable in exactly
                // one place: "_" means a space.
                decodeQuotedPrintable(Data(payload.replacingOccurrences(of: "_", with: " ").utf8))
            default:
                nil
            }

            result += decoded.map { decodeText($0, charset: charset) } ?? String(payload)
            rest = afterCharset[close.upperBound...]
        }
        result += rest
        return result
    }
}
