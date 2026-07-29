//
//  PushPayloadMapper.swift
//  KyPost
//
//  Maps APNs userInfo dictionaries to domain payloads (spec §3, §5).
//  Binding contract with Android — exact keys: messageId, senderName,
//  emailSubject, Keywords (capital K); MFA: type == "mfa_challenge",
//  challengeId.
//

import Foundation

/// An email arrival announced via push; becomes a PushNotification history
/// entry once a seq is assigned (push mode has no server seq).
struct MailPushPayload: Equatable, Sendable {
    var messageId: String
    var senderName: String
    var emailSubject: String
    var keywords: [String]

    func toNotification(seq: Int, receivedAt: Date) -> PushNotification {
        PushNotification(
            seq: seq,
            messageId: messageId,
            senderName: senderName,
            emailSubject: emailSubject,
            keywords: keywords,
            receivedAt: receivedAt,
            read: false
        )
    }
}

enum PushPayload: Equatable, Sendable {
    case mail(MailPushPayload)
    case mfaChallenge(MfaChallenge)
}

enum PushPayloadMapper {
    /// Returns nil for payloads that are neither a mail arrival nor an MFA
    /// challenge (missing required keys).
    static func map(userInfo: [AnyHashable: Any], receivedAt: Date = Date()) -> PushPayload? {
        if userInfo["type"] as? String == MfaChallenge.payloadType {
            guard let challengeId = userInfo["challengeId"] as? String, !challengeId.isEmpty else {
                return nil
            }
            return .mfaChallenge(MfaChallenge(
                challengeId: challengeId,
                receivedAt: receivedAt,
                matchDigits: matchDigits(from: userInfo["matchDigits"]),
                decoyDigits: decoyDigits(from: userInfo["decoyDigits"])
            ))
        }

        guard let messageId = userInfo["messageId"] as? String, !messageId.isEmpty else {
            return nil
        }
        return .mail(MailPushPayload(
            messageId: messageId,
            senderName: userInfo["senderName"] as? String ?? "",
            emailSubject: userInfo["emailSubject"] as? String ?? "",
            keywords: keywords(from: userInfo["Keywords"])
        ))
    }

    /// Only well-formed digit runs survive: these drive tap targets on a
    /// security screen, so neither the server nor anyone who can reach the push
    /// channel gets to put arbitrary text on a button. A malformed value is
    /// treated as absent, which drops the screen back to plain approve/deny.
    private static func matchDigits(from value: Any?) -> String {
        guard let raw = value as? String else { return "" }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        // ASCII-only: `isNumber` alone also accepts other Unicode numerals, and
        // a tile reading "٤٧" would never match what the browser displays.
        guard trimmed.count == MfaChallenge.matchDigitsLength,
              trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return ""
        }
        return trimmed
    }

    /// Comma-joined by the backend, same as Keywords — APNs data values are strings.
    private static func decoyDigits(from value: Any?) -> [String] {
        guard let joined = value as? String else { return [] }
        var seen: [String] = []
        for part in joined.split(separator: ",") {
            let candidate = matchDigits(from: String(part))
            if !candidate.isEmpty && !seen.contains(candidate) {
                seen.append(candidate)
            }
        }
        return seen
    }

    /// APNs data values are strings, so the backend sends Keywords
    /// comma-joined; local (pull-mode) notifications carry a real array.
    private static func keywords(from value: Any?) -> [String] {
        if let array = value as? [String] {
            return array
        }
        if let joined = value as? String {
            return joined.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        return []
    }
}
