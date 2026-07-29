//
//  DesktopPairingService.swift
//  KyPost
//
//  Desktop pairing flow (Desktop Pairing guide): validate the one-time code,
//  exchange it for a session token, and persist the session in the Keychain.
//

import Foundation

/// `@MainActor` for the same reason as DeviceRegistrationService: `inFlight`
/// and `completed` are unsynchronised dictionaries, and every caller
/// (DesktopPairingViewModel) already runs on the main actor.
@MainActor
final class DesktopPairingService {
    /// Codes live 5 minutes server-side, so a memo older than that answers a
    /// question the server would answer differently. Bounded on both axes: no
    /// pairing code and no paired-account email outlives its own TTL in memory.
    private static let completedTTL: TimeInterval = 5 * 60

    private let client: DesktopRegistrationClient
    private let sessionStore: DesktopSessionStore
    private let now: () -> Date

    /// One registration per code. A pairing deep link is delivered to every
    /// open main window and each auto-pairs, so without this guard a single
    /// click can register the same computer several times; codes are also
    /// single-use, so a second register call could never succeed anyway.
    private var inFlight: [String: Task<DesktopRegistrationOutcome, Never>] = [:]
    private var completed: [String: (outcome: DesktopRegistrationOutcome, at: Date)] = [:]

    init(
        client: DesktopRegistrationClient,
        sessionStore: DesktopSessionStore,
        now: @escaping () -> Date = Date.init
    ) {
        self.client = client
        self.sessionStore = sessionStore
        self.now = now
    }

    /// Guide checklist: validate the code format before sending. The guide
    /// says "32 hex chars" but its own sample codes are alphanumeric, so only
    /// length + alphanumeric are enforced.
    static func isValidCode(_ code: String) -> Bool {
        code.count == Config.desktopPairingCodeLength
            && code.allSatisfy { $0.isLetter || $0.isNumber }
    }

    /// Exchanges the code for a session token and persists it on success.
    /// Codes are single-use, so a failed exchange is never retried here —
    /// the user gets a fresh code from the web app instead. Repeat and
    /// concurrent calls with the same code share one registration.
    func pair(params: DesktopPairingParams) async -> DesktopRegistrationOutcome {
        guard Self.isValidCode(params.code) else {
            return .failure(
                "Malformed pairing code — expected \(Config.desktopPairingCodeLength) characters."
            )
        }
        pruneCompleted()
        if let memo = completed[params.code] {
            return memo.outcome
        }
        if let task = inFlight[params.code] {
            return await task.value
        }
        let task = Task { await performPair(params: params) }
        inFlight[params.code] = task
        let outcome = await task.value
        inFlight[params.code] = nil
        completed[params.code] = (outcome, now())
        return outcome
    }

    /// Drops memos for codes the server has already expired. Without this the
    /// map grew for the process lifetime, holding every pairing code and the
    /// account email each one resolved to.
    private func pruneCompleted() {
        let cutoff = now().addingTimeInterval(-Self.completedTTL)
        completed = completed.filter { $0.value.at > cutoff }
    }

    private func performPair(params: DesktopPairingParams) async -> DesktopRegistrationOutcome {
        let outcome = await client.register(params: params)
        if case .success(let response) = outcome {
            do {
                try sessionStore.saveSession(DesktopSession(
                    sessionToken: response.sessionToken,
                    expiresAt: Date(timeIntervalSinceNow: TimeInterval(response.expiresIn)),
                    userId: response.userId,
                    userEmail: response.userEmail,
                    srv: params.srv,
                    pairedAt: Date()
                ))
            } catch {
                return .failure("Paired, but the session could not be saved: \(error)")
            }
        }
        return outcome
    }

    /// "Forget This Computer" (guide checklist): clears the stored session.
    func unpair() throws {
        try sessionStore.clear()
    }
}
