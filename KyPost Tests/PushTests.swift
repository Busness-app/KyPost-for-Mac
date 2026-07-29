//
//  PushTests.swift
//  KyPost Tests
//
//  Phase 5 tests: payload mapping, pull dedupe + cursor handoff, synthesized
//  seqs for push-mode arrivals, registration persistence, MFA use case.
//

import Foundation
import Testing
import UserNotifications
@testable import KyPost

// MARK: - Helpers



private func scratchStores() -> (defaults: UserDefaults, keychain: KeychainStorage) {
    (
        UserDefaults(suiteName: "test.\(UUID().uuidString)")!,
        KeychainStorage(service: "com.urlxl.mail.tests.\(UUID().uuidString)")
    )
}

private func makePairing(lastDeviceId: String? = "dev-1", deviceSecret: String = "s1") -> Pairing {
    Pairing(
        sub: "u1", deviceSecret: deviceSecret, srv: server, registrationUrl: nil,
        pairingToken: "pt", lastDeviceId: lastDeviceId, pairedAt: Date()
    )
}

// MARK: - Payload mapping

@Suite struct PushPayloadMapperTests {
    @Test func mapsMailPayloadWithContractKeys() throws {
        // Exact keys from spec §3, including capital-K Keywords.
        let userInfo: [AnyHashable: Any] = [
            "messageId": "m-1",
            "senderName": "Ada",
            "emailSubject": "Hello",
            "Keywords": ["Important", "Work"],
        ]
        guard case .mail(let mail)? = PushPayloadMapper.map(userInfo: userInfo) else {
            Issue.record("Expected mail payload")
            return
        }
        #expect(mail.messageId == "m-1")
        #expect(mail.senderName == "Ada")
        #expect(mail.emailSubject == "Hello")
        #expect(mail.keywords == ["Important", "Work"])
    }

    @Test func mapsCommaJoinedKeywordsFromApnsData() throws {
        // APNs data values are strings; the backend comma-joins Keywords.
        let userInfo: [AnyHashable: Any] = [
            "messageId": "m-3",
            "Keywords": "Important, Work,,Receipts",
        ]
        guard case .mail(let mail)? = PushPayloadMapper.map(userInfo: userInfo) else {
            Issue.record("Expected mail payload")
            return
        }
        #expect(mail.keywords == ["Important", "Work", "Receipts"])
    }

    @Test func mapsMinimalMailPayload() {
        let payload = PushPayloadMapper.map(userInfo: ["messageId": "m-2"])
        #expect(payload == .mail(MailPushPayload(
            messageId: "m-2", senderName: "", emailSubject: "", keywords: []
        )))
    }

    @Test func mapsMfaChallenge() throws {
        let received = Date(timeIntervalSince1970: 1_750_000_000)
        let payload = PushPayloadMapper.map(
            userInfo: ["type": "mfa_challenge", "challengeId": "c-1"],
            receivedAt: received
        )
        #expect(payload == .mfaChallenge(MfaChallenge(challengeId: "c-1", receivedAt: received)))
    }

    @Test func mapsMfaChallengeNumberMatchFields() throws {
        let received = Date(timeIntervalSince1970: 1_750_000_000)
        let payload = PushPayloadMapper.map(
            userInfo: [
                "type": "mfa_challenge",
                "challengeId": "c-1",
                "matchDigits": "47",
                // Comma-joined, same convention as Keywords.
                "decoyDigits": "08,91",
            ],
            receivedAt: received
        )
        #expect(payload == .mfaChallenge(MfaChallenge(
            challengeId: "c-1",
            receivedAt: received,
            matchDigits: "47",
            decoyDigits: ["08", "91"]
        )))
    }

    @Test func dropsMalformedMatchDigits() throws {
        // These drive tap targets on a security screen, so anything that is not
        // a two-digit run is treated as absent rather than rendered.
        for bad in ["4", "471", "4x", "", " "] {
            let payload = PushPayloadMapper.map(
                userInfo: ["type": "mfa_challenge", "challengeId": "c-1", "matchDigits": bad]
            )
            guard case .mfaChallenge(let challenge) = payload else {
                Issue.record("Expected an MFA challenge for matchDigits \(bad.debugDescription)")
                return
            }
            #expect(challenge.matchDigits == "")
        }
    }

    @Test func dropsMalformedDecoyDigitsAndDuplicates() throws {
        let payload = PushPayloadMapper.map(
            userInfo: [
                "type": "mfa_challenge",
                "challengeId": "c-1",
                "matchDigits": "47",
                "decoyDigits": "08,bad,08,,913,91",
            ]
        )
        guard case .mfaChallenge(let challenge) = payload else {
            Issue.record("Expected an MFA challenge")
            return
        }
        #expect(challenge.decoyDigits == ["08", "91"])
    }

    @Test func rejectsUnrecognizedPayloads() {
        #expect(PushPayloadMapper.map(userInfo: [:]) == nil)
        #expect(PushPayloadMapper.map(userInfo: ["foo": "bar"]) == nil)
        // MFA without a challengeId is invalid, not a mail fallback.
        #expect(PushPayloadMapper.map(userInfo: ["type": "mfa_challenge"]) == nil)
        #expect(PushPayloadMapper.map(userInfo: ["messageId": ""]) == nil)
    }
}

// MARK: - Number matching

@Suite struct MfaNumberMatchTests {
    @Test func returnsNilWithoutAUsableNumber() {
        // No number from the server means number matching is unavailable, and
        // the screen then offers Deny only — never a plain Approve button, which
        // is the tap an MFA-fatigue attack is trying to collect.
        #expect(MfaNumberMatch.options(challengeId: "c-1", correct: "", serverDecoys: []) == nil)
        #expect(MfaNumberMatch.options(challengeId: "c-1", correct: "4", serverDecoys: []) == nil)
        #expect(MfaNumberMatch.options(challengeId: "c-1", correct: "4x", serverDecoys: []) == nil)
    }

    @Test func includesTheCorrectValueAmongThreeDistinctOptions() throws {
        let options = try #require(
            MfaNumberMatch.options(challengeId: "c-1", correct: "47", serverDecoys: ["08", "91"])
        )
        #expect(options.count == MfaNumberMatch.choiceCount)
        #expect(options.contains("47"))
        #expect(Set(options).count == MfaNumberMatch.choiceCount)
    }

    @Test func fillsMissingDecoysDeterministically() throws {
        // A redraw must not reshuffle the buttons under the user's finger, so
        // the filler is derived from the challenge id rather than randomly.
        let first = try #require(
            MfaNumberMatch.options(challengeId: "c-1", correct: "47", serverDecoys: [])
        )
        let second = try #require(
            MfaNumberMatch.options(challengeId: "c-1", correct: "47", serverDecoys: [])
        )
        #expect(first == second)
        #expect(first.count == MfaNumberMatch.choiceCount)
        #expect(first.contains("47"))
        #expect(Set(first).count == MfaNumberMatch.choiceCount)
    }

    @Test func neverOffersTheCorrectValueTwice() throws {
        // A server decoy colliding with the answer must not produce a duplicate
        // tile — two correct-looking buttons would make the choice meaningless.
        let options = try #require(
            MfaNumberMatch.options(challengeId: "c-1", correct: "47", serverDecoys: ["47", "47"])
        )
        #expect(options.filter { $0 == "47" }.count == 1)
        #expect(Set(options).count == MfaNumberMatch.choiceCount)
    }

    @Test func orderDoesNotPinTheAnswerToOnePosition() {
        // Sorting by a hash of (challengeId, value) rather than leaving the
        // answer appended last, so it is not always the rightmost tile.
        let positions = (0..<40).compactMap { index -> Int? in
            MfaNumberMatch.options(challengeId: "challenge-\(index)", correct: "47", serverDecoys: ["08", "91"])?
                .firstIndex(of: "47")
        }
        #expect(Set(positions).count > 1)
    }
}

// MARK: - Notification categories

@MainActor
@Suite struct PushNotificationDispatcherCategoryTests {
    @Test func mfaCategoryOffersNoApproveAction() throws {
        // Approving requires the number the browser is showing, which the
        // backend verifies and a banner cannot present. An Approve button here
        // could only send a blind approval — the exact tap an MFA-fatigue
        // attack harvests, and one the server now refuses anyway.
        let mfa = try #require(
            PushNotificationDispatcher.categories.first { $0.identifier == PushNotificationDispatcher.mfaCategoryId }
        )
        #expect(!mfa.actions.contains { $0.identifier == PushNotificationDispatcher.approveActionId })
    }

    @Test func denyActionRemainsDestructiveAndUnauthenticated() throws {
        // Denying isn't a sensitive action, so no reason to gate it — this
        // pins the deny action's options so a future edit can't silently
        // change them alongside the approve fix.
        let mfa = try #require(
            PushNotificationDispatcher.categories.first { $0.identifier == PushNotificationDispatcher.mfaCategoryId }
        )
        let deny = try #require(
            mfa.actions.first { $0.identifier == PushNotificationDispatcher.denyActionId }
        )
        #expect(deny.options == [.destructive])
    }
}

// MARK: - PushRepository

@Suite struct PushRepositoryTests {
    private struct Environment {
        var repository: PushRepository
        var cursorStore: NotificationCursorStore
        var settings: PushSettingsStore
    }

    private func makeEnvironment(client: HTTPClient, paired: Bool = true) throws -> Environment {
        let (defaults, keychain) = scratchStores()
        let pairingStore = SecurePairingStore(keychain: keychain)
        if paired {
            try pairingStore.savePairing(makePairing())
        }
        let db = try AppDatabase(inMemory: true)
        let cursorStore = NotificationCursorStore(defaults: defaults)
        let settings = PushSettingsStore(defaults: defaults)
        let repository = PushRepository(
            dao: PushNotificationDAO(modelContainer: db.container),
            cursorStore: cursorStore,
            client: PushNotificationClient(httpClient: client),
            securePairingStore: pairingStore,
            pushSettingsStore: settings
        )
        return Environment(repository: repository, cursorStore: cursorStore, settings: settings)
    }

    @Test func pushArrivalsGetUniqueSynthesizedSeqs() async throws {
        let env = try makeEnvironment(client: stubClient())
        let payload = MailPushPayload(
            messageId: "m-1", senderName: "Ada", emailSubject: "Hi", keywords: []
        )
        let sameInstant = Date()
        let first = try await env.repository.recordPushArrival(payload, receivedAt: sameInstant)
        let second = try await env.repository.recordPushArrival(payload, receivedAt: sameInstant)

        #expect(first.seq != second.seq)
        #expect(try await env.repository.history().count == 2)
    }

    @Test func pullDeduplicatesBySeqAndAdvancesCursorAfterHandoff() async throws {
        let json = """
        {
          "notifications": [
            { "seq": 3, "messageId": "m-3", "senderName": "A", "emailSubject": "s3" },
            { "seq": 5, "messageId": "m-5", "senderName": "B", "emailSubject": "s5" }
          ],
          "cursor": 5
        }
        """
        let client = stubClient(json: json) { request in
            let url = request.url!.absoluteString
            #expect(url.hasPrefix("\(server)/api/notifications/native/pull?"))
            #expect(url.contains("after=3"))
            #expect(!url.contains("sub="))
            #expect(!url.contains("hash="))
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Id") == "dev-1")
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Secret") != nil)
        }
        let env = try makeEnvironment(client: client)
        env.cursorStore.advance(to: 3)

        let delivered = try await env.repository.pullOnce()
        // seq 3 <= cursor: deduped; only seq 5 is new.
        #expect(delivered.map(\.seq) == [5])
        #expect(env.cursorStore.lastCursor == 5)
        #expect(try await env.repository.history().map(\.seq) == [5])
    }

    @Test func storedPullEndpointOverridesDerivedOne() async throws {
        let client = stubClient(json: #"{"notifications": [], "cursor": 0}"#) { request in
            #expect(request.url!.absoluteString.hasPrefix("https://pull.example.com/custom?"))
        }
        let env = try makeEnvironment(client: client)
        env.settings.pullEndpoint = "https://pull.example.com/custom"
        _ = try await env.repository.pullOnce()
    }

    @Test func pullWithoutPairingThrows() async throws {
        let env = try makeEnvironment(client: stubClient(), paired: false)
        await #expect(throws: MailSourceError.notPaired) {
            try await env.repository.pullOnce()
        }
    }
}

// MARK: - DeviceRegistrationService

// DeviceRegistrationService is @MainActor: `inFlight` and the pin-capture
// closures are unsynchronised mutable state, and every production caller
// already runs there.
@MainActor
@Suite struct DeviceRegistrationServiceTests {
    private struct Environment {
        var service: DeviceRegistrationService
        var pairingStore: SecurePairingStore
        var settings: PushSettingsStore
    }

    private func makeEnvironment(client: HTTPClient, paired: Bool = false) throws -> Environment {
        let (defaults, keychain) = scratchStores()
        let pairingStore = SecurePairingStore(keychain: keychain)
        if paired {
            try pairingStore.savePairing(makePairing())
        }
        let settings = PushSettingsStore(defaults: defaults)
        let service = DeviceRegistrationService(
            client: NativeRegistrationClient(httpClient: client),
            securePairingStore: pairingStore,
            pushSettingsStore: settings
        )
        return Environment(service: service, pairingStore: pairingStore, settings: settings)
    }

    private let params = PairingParams(sub: "u1", srv: server, pt: "pt-1")

    @Test func successfulPairingPersistsEverything() async throws {
        let json = #"{"ok": true, "deviceId": "dev-7", "deviceSecret": "s-7", "deliveryMode": "pull"}"#
        let env = try makeEnvironment(client: stubClient(json: json))

        let outcome = await env.service.pair(params: params, deviceToken: "apns-token")
        guard case .success = outcome else {
            Issue.record("Expected success, got \(outcome)")
            return
        }

        let pairing = try #require(try env.pairingStore.loadPairing())
        #expect(pairing.sub == "u1")
        #expect(pairing.lastDeviceId == "dev-7")
        #expect(pairing.deviceSecret == "s-7")
        #expect(env.settings.deliveryMode == .pull)
        // pullEndpoint absent in response → derived from srv (spec §3).
        #expect(env.settings.pullEndpoint == "\(server)/api/notifications/native/pull")
    }

    @Test func failedPairingSavesNothing() async throws {
        let env = try makeEnvironment(client: stubClient(status: 403))
        let outcome = await env.service.pair(params: params, deviceToken: "t")
        #expect(outcome == .unauthorized)
        #expect(try env.pairingStore.loadPairing() == nil)
        #expect(env.settings.deliveryMode == nil)
    }

    @Test func reregisterUsesStoredPairing() async throws {
        let client = stubClient(json: #"{"ok": true, "deviceId": "dev-8"}"#) { request in
            #expect(
                request.url!.absoluteString
                    == "\(server)/api/notifications/native/register"
            )
            // Register sends no header-based auth at all, initial or
            // re-registration alike — see NativeRegistrationClient.register.
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Id") == nil)
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Secret") == nil)
        }
        let env = try makeEnvironment(client: client, paired: true)
        let outcome = await env.service.reregisterIfPaired(deviceToken: "t2")
        #expect(outcome != nil)
        #expect(try env.pairingStore.loadPairing()?.lastDeviceId == "dev-8")
    }

    /// Every successful register mints a brand-new secret, invalidating the
    /// previous one — the stored value must be overwritten, not kept.
    @Test func reregisterOverwritesStoredDeviceSecret() async throws {
        let client = stubClient(json: #"{"ok": true, "deviceId": "dev-8", "deviceSecret": "new-secret"}"#)
        let env = try makeEnvironment(client: client, paired: true)
        let before = try #require(try env.pairingStore.loadPairing())
        #expect(before.deviceSecret == "s1")

        let outcome = await env.service.reregisterIfPaired(deviceToken: "t2")

        #expect(outcome != nil)
        #expect(try env.pairingStore.loadPairing()?.deviceSecret == "new-secret")
    }

    @Test func reregisterWithoutPairingIsNoOp() async throws {
        let env = try makeEnvironment(client: stubClient(), paired: false)
        let outcome = await env.service.reregisterIfPaired(deviceToken: "t")
        #expect(outcome == nil)
    }

    // MARK: - TOFU pinning capture

    @Test func theFirstSuccessfulPairingPinsTheObservedKey() async throws {
        let json = #"{"ok": true, "deviceId": "dev-7", "deviceSecret": "s-7"}"#
        let env = try makeEnvironment(client: stubClient(json: json))
        env.service.observedSpkiHash = { host in
            host == "relay.example.com" ? "hash-first" : nil
        }

        _ = await env.service.pair(params: params, deviceToken: "t")

        #expect(env.pairingStore.pinnedSpkiHash == "hash-first")
    }

    /// Trust on FIRST use, not on every use. `performPair` also runs on every
    /// foreground and APNs token refresh, so re-pinning here would silently
    /// adopt whatever key was last seen — one interception would become a
    /// permanent pin for the attacker's key and lock out the real relay.
    @Test func reregistrationNeverRepinsAnAlreadyPinnedRelay() async throws {
        let json = #"{"ok": true, "deviceId": "dev-8"}"#
        let env = try makeEnvironment(client: stubClient(json: json), paired: true)
        try env.pairingStore.setPinnedSpkiHash("hash-first")
        env.service.observedSpkiHash = { _ in "hash-attacker" }

        _ = await env.service.reregisterIfPaired(deviceToken: "t2")

        #expect(env.pairingStore.pinnedSpkiHash == "hash-first")
    }

    /// Clearing the pairing is the documented rotation recovery, so the next
    /// pairing must be free to pin again.
    @Test func pinningResumesAfterThePairingIsCleared() async throws {
        let json = #"{"ok": true, "deviceId": "dev-7", "deviceSecret": "s-7"}"#
        let env = try makeEnvironment(client: stubClient(json: json), paired: true)
        try env.pairingStore.setPinnedSpkiHash("hash-first")
        env.service.observedSpkiHash = { _ in "hash-rotated" }

        try env.pairingStore.clear()
        _ = await env.service.pair(params: params, deviceToken: "t")

        #expect(env.pairingStore.pinnedSpkiHash == "hash-rotated")
    }

    /// Re-registration must carry the stored deviceId so the server updates
    /// the existing device row instead of pairing the computer again.
    @Test func reregisterSendsStoredDeviceId() async throws {
        let client = stubClient(json: #"{"ok": true, "deviceId": "dev-1"}"#) { request in
            let body = request.httpBody.flatMap { String(decoding: $0, as: UTF8.self) } ?? ""
            #expect(body.contains(#""deviceId":"dev-1""#))
        }
        let env = try makeEnvironment(client: client, paired: true)
        let outcome = await env.service.reregisterIfPaired(deviceToken: "t2")
        #expect(outcome != nil)
    }

    /// First pairing has no deviceId yet — the server mints one.
    @Test func initialPairingOmitsDeviceId() async throws {
        let client = stubClient(json: #"{"ok": true, "deviceId": "dev-9"}"#) { request in
            let body = request.httpBody.flatMap { String(decoding: $0, as: UTF8.self) } ?? ""
            #expect(!body.contains(#""deviceId""#))
        }
        let env = try makeEnvironment(client: client)
        let outcome = await env.service.pair(params: params, deviceToken: "t")
        guard case .success = outcome else {
            Issue.record("Expected success, got \(outcome)")
            return
        }
    }
}

// MARK: - PushPairingViewModel confirmation flow (pairing-hijack fix)

@MainActor
@Suite struct PushPairingViewModelTests {
    private func makeViewModel(paired: Bool = false) throws -> PushPairingViewModel {
        let (defaults, keychain) = scratchStores()
        let pairingStore = SecurePairingStore(keychain: keychain)
        if paired {
            try pairingStore.savePairing(makePairing())
        }
        return PushPairingViewModel(
            registrationService: DeviceRegistrationService(
                client: NativeRegistrationClient(httpClient: stubClient()),
                securePairingStore: pairingStore,
                pushSettingsStore: PushSettingsStore(defaults: defaults)
            ),
            pushSettingsStore: PushSettingsStore(defaults: defaults),
            securePairingStore: pairingStore
        )
    }

    private let params = PairingParams(sub: "u1", srv: "https://relay.example.com", pt: "pt-1")

    @Test func presentShowsTheDestinationHostBeforeAnyNetworkCall() throws {
        let viewModel = try makeViewModel(paired: false)
        viewModel.present(params: params)
        #expect(viewModel.state == .confirming(
            PendingPairingConfirmation(params: params, existingHost: nil)
        ))
    }

    @Test func presentWarnsWhenAcceptingWouldReplaceAnExistingPairing() throws {
        let viewModel = try makeViewModel(paired: true)
        viewModel.present(params: params)
        #expect(viewModel.state == .confirming(
            PendingPairingConfirmation(params: params, existingHost: URL(string: server)?.host)
        ))
    }

    @Test func pairFromPastedLinkAsksForConfirmationInsteadOfPairingImmediately() async throws {
        let viewModel = try makeViewModel()
        viewModel.pastedLink = "kypost://native-pair?sub=u1&srv=https://relay.example.com&pt=pt-1"
        await viewModel.pairFromPastedLink()
        guard case .confirming(let confirmation) = viewModel.state else {
            Issue.record("Expected .confirming, got \(viewModel.state)")
            return
        }
        #expect(confirmation.params == params)
    }

    @Test func pairFromScannedCodeAsksForConfirmationInsteadOfPairingImmediately() async throws {
        let viewModel = try makeViewModel()
        await viewModel.pairFromScannedCode("kypost://native-pair?sub=u1&srv=https://relay.example.com&pt=pt-1")
        guard case .confirming(let confirmation) = viewModel.state else {
            Issue.record("Expected .confirming, got \(viewModel.state)")
            return
        }
        #expect(confirmation.params == params)
    }

    @Test func confirmingThenPairStillCompletesRegistration() async throws {
        let (defaults, keychain) = scratchStores()
        let pairingStore = SecurePairingStore(keychain: keychain)
        let viewModel = PushPairingViewModel(
            registrationService: DeviceRegistrationService(
                client: NativeRegistrationClient(
                    httpClient: stubClient(json: #"{"ok": true, "deviceId": "dev-7"}"#)
                ),
                securePairingStore: pairingStore,
                pushSettingsStore: PushSettingsStore(defaults: defaults)
            ),
            pushSettingsStore: PushSettingsStore(defaults: defaults),
            securePairingStore: pairingStore
        )
        viewModel.present(params: params)
        await viewModel.pair(params: params)
        guard case .paired = viewModel.state else {
            Issue.record("Expected .paired, got \(viewModel.state)")
            return
        }
    }

    @Test func resetReturnsToIdleFromConfirming() throws {
        let viewModel = try makeViewModel()
        viewModel.present(params: params)
        viewModel.reset()
        #expect(viewModel.state == .idle)
    }
}

// MARK: - DeviceRegistrationService dedupe (one registration per click)

@MainActor
@Suite struct DeviceRegistrationServiceDedupeTests {
    private let params = PairingParams(sub: "u1", srv: server, pt: "pt-1")

    private func makeService(counter: Box<Int>) -> DeviceRegistrationService {
        let client = HTTPClient { request in
            counter.mutate { $0 += 1 }
            try? await Task.sleep(for: .milliseconds(10))
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(#"{"ok": true, "deviceId": "dev-7"}"#.utf8), response)
        }
        let (defaults, keychain) = scratchStores()
        return DeviceRegistrationService(
            client: NativeRegistrationClient(httpClient: client),
            securePairingStore: SecurePairingStore(keychain: keychain),
            pushSettingsStore: PushSettingsStore(defaults: defaults)
        )
    }

    /// The pairing deep link is delivered to every open main window and each
    /// auto-pairs; concurrent calls with one pairing token + device token
    /// must collapse into a single registration.
    @Test func concurrentPairsWithSameTokensRegisterOnce() async {
        let counter = Box<Int>(0)
        let service = makeService(counter: counter)
        async let first = service.pair(params: params, deviceToken: "t")
        async let second = service.pair(params: params, deviceToken: "t")
        _ = await [first, second]
        #expect(counter.value == 1)
    }

    /// A refreshed APNs token is a different registration and must not be
    /// swallowed by the dedupe guard.
    @Test func newDeviceTokenRegistersAgain() async {
        let counter = Box<Int>(0)
        let service = makeService(counter: counter)
        _ = await service.pair(params: params, deviceToken: "t1")
        _ = await service.pair(params: params, deviceToken: "t2")
        #expect(counter.value == 2)
    }
}

// MARK: - ApproveMfaChallengeUseCase

@Suite struct ApproveMfaChallengeUseCaseTests {
    private func makeUseCase(client: HTTPClient, paired: Bool) throws -> ApproveMfaChallengeUseCase {
        let (_, keychain) = scratchStores()
        let pairingStore = SecurePairingStore(keychain: keychain)
        if paired {
            try pairingStore.savePairing(makePairing())
        }
        return ApproveMfaChallengeUseCase(
            client: MfaResponseClient(httpClient: client),
            securePairingStore: pairingStore
        )
    }

    @Test func approvesThroughPairedServer() async throws {
        let client = stubClient(json: #"{"ok": true}"#) { request in
            #expect(request.url!.absoluteString.hasPrefix("\(server)/api/mfa/push/respond"))
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Id") == "dev-1")
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Secret") == "s1")
            let body = request.httpBody.flatMap { String(decoding: $0, as: UTF8.self) } ?? ""
            #expect(body.contains(#""challengeId":"c-1""#))
            #expect(!body.contains("subscriberId"))
            #expect(!body.contains("subscriberHash"))
            #expect(!body.contains("deviceId"))
            #expect(body.contains(#""approve":true"#))
            // Threaded from the approval screen through to the wire — the
            // backend refuses an approval that does not carry it.
            #expect(body.contains(#""matchDigits":"47""#))
        }
        let useCase = try makeUseCase(client: client, paired: true)
        let outcome = await useCase(challengeId: "c-1", approved: true, matchDigits: "47")
        #expect(outcome == .success)
    }

    @Test func failsWhenUnpaired() async throws {
        let useCase = try makeUseCase(client: stubClient(), paired: false)
        let outcome = await useCase(challengeId: "c-1", approved: false)
        #expect(outcome == .failure("Device is not paired"))
    }

    @Test func failsWithoutDeviceId() async throws {
        let (_, keychain) = scratchStores()
        let pairingStore = SecurePairingStore(keychain: keychain)
        try pairingStore.savePairing(makePairing(lastDeviceId: nil))
        let useCase = ApproveMfaChallengeUseCase(
            client: MfaResponseClient(httpClient: stubClient()),
            securePairingStore: pairingStore
        )
        let outcome = await useCase(challengeId: "c-1", approved: true)
        guard case .failure = outcome else {
            Issue.record("Expected failure without a device ID, got \(outcome)")
            return
        }
    }

    @Test func failsWithoutDeviceSecret() async throws {
        let (_, keychain) = scratchStores()
        let pairingStore = SecurePairingStore(keychain: keychain)
        try pairingStore.savePairing(makePairing(deviceSecret: ""))
        let useCase = ApproveMfaChallengeUseCase(
            client: MfaResponseClient(httpClient: stubClient()),
            securePairingStore: pairingStore
        )
        let outcome = await useCase(challengeId: "c-1", approved: true)
        guard case .failure = outcome else {
            Issue.record("Expected failure without a device secret, got \(outcome)")
            return
        }
    }
}

@Suite struct DeregisterDeviceUseCaseTests {
    private func makeUseCase(client: HTTPClient, pairing: Pairing?) throws -> DeregisterDeviceUseCase {
        let (_, keychain) = scratchStores()
        let pairingStore = SecurePairingStore(keychain: keychain)
        if let pairing {
            try pairingStore.savePairing(pairing)
        }
        return DeregisterDeviceUseCase(
            client: DeregisterClient(httpClient: client),
            securePairingStore: pairingStore
        )
    }

    @Test func succeedsThroughPairedServer() async throws {
        let client = stubClient(json: #"{"ok": true}"#) { request in
            #expect(request.url!.absoluteString.hasPrefix("\(server)/api/notifications/native/deregister"))
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Id") == "dev-1")
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Secret") == "s1")
        }
        let useCase = try makeUseCase(client: client, pairing: makePairing())
        let outcome = await useCase()
        #expect(outcome == .success)
    }

    @Test func failsWhenUnpaired() async throws {
        let useCase = try makeUseCase(client: stubClient(), pairing: nil)
        let outcome = await useCase()
        #expect(outcome == .failure("Device is not registered"))
    }

    @Test func skipsNetworkCallForPreMigrationPairingWithNoSecret() async throws {
        let requestFired = Box(false)
        let client = stubClient { _ in requestFired.value = true }
        let useCase = try makeUseCase(client: client, pairing: makePairing(deviceSecret: ""))
        let outcome = await useCase()
        #expect(!requestFired.value)
        #expect(outcome == .failure("Device is not registered"))
    }

    @Test func unauthorizedFrom401() async throws {
        let client = stubClient(status: 401)
        let useCase = try makeUseCase(client: client, pairing: makePairing())
        let outcome = await useCase()
        #expect(outcome == .unauthorized)
    }
}

// MARK: - The number-match downgrade

@MainActor
@Suite struct MfaApprovalViewModelTests {
    private func makeUseCase(_ client: HTTPClient) -> ApproveMfaChallengeUseCase {
        let (_, keychain) = scratchStores()
        let store = SecurePairingStore(keychain: keychain)
        try? store.savePairing(makePairing())
        return ApproveMfaChallengeUseCase(
            client: MfaResponseClient(httpClient: client),
            securePairingStore: store
        )
    }

    /// A payload with no usable number leaves no way to approve. The plain
    /// Approve fallback handed the whole anti-fatigue control to whoever shapes
    /// the push payload — and the server refuses a numberless approval anyway,
    /// so it could only ever produce a failure.
    @Test func aChallengeWithoutANumberOffersNoOptions() {
        let viewModel = MfaApprovalViewModel(
            challengeId: "c1",
            approveMfaChallenge: makeUseCase(stubClient())
        )
        #expect(viewModel.matchOptions == nil)
    }

    @Test func approvingWithoutANumberIsRefusedBeforeAnyRequest() async {
        let sent = Box(0)
        let client = stubClient { _ in sent.mutate { $0 += 1 } }
        let viewModel = MfaApprovalViewModel(
            challengeId: "c1",
            approveMfaChallenge: makeUseCase(client)
        )
        await viewModel.respond(approved: true)
        #expect(sent.value == 0)
        guard case .failed = viewModel.state else {
            Issue.record("expected .failed, got \(viewModel.state)")
            return
        }
    }

    /// Deny must never depend on reading a number off another screen.
    @Test func denyingWithoutANumberStillWorks() async {
        let viewModel = MfaApprovalViewModel(
            challengeId: "c1",
            approveMfaChallenge: makeUseCase(stubClient(json: #"{"ok": true}"#))
        )
        await viewModel.respond(approved: false)
        #expect(viewModel.state == .done("Sign-in denied"))
    }

    @Test func aWrongNumberDeniesRatherThanRetries() async {
        let body = Box("")
        let client = stubClient(json: #"{"ok": true}"#) { request in
            body.mutate { $0 = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? "" }
        }
        let viewModel = MfaApprovalViewModel(
            challengeId: "c1",
            matchDigits: "47",
            decoyDigits: ["11", "22"],
            approveMfaChallenge: makeUseCase(client)
        )
        await viewModel.choose("11")
        #expect(body.value.contains(#""approve":false"#))
        guard case .done(let message) = viewModel.state else {
            Issue.record("expected .done, got \(viewModel.state)")
            return
        }
        #expect(message.contains("not the number"))
    }
}

@Suite struct MfaNumberlessRejectionMessageTests {
    /// A 400 on a numberless approve is not "you picked the wrong number" —
    /// telling the user they mistyped a number they were never shown sent them
    /// round a loop with no exit.
    @Test func aNumberlessRejectionDoesNotBlameTheNumber() async {
        let outcome = await MfaResponseClient(httpClient: stubClient(status: 400)).respond(
            serverUrl: "https://relay.example.com",
            auth: RelayAuth(deviceId: "d1", deviceSecret: "s1"),
            challengeId: "c1",
            approved: true,
            matchDigits: ""
        )
        guard case .failure(let message) = outcome else {
            Issue.record("expected .failure, got \(outcome)")
            return
        }
        #expect(!message.contains("not the number"))
    }

    @Test func aWrongNumberStillBlamesTheNumber() async {
        let outcome = await MfaResponseClient(httpClient: stubClient(status: 400)).respond(
            serverUrl: "https://relay.example.com",
            auth: RelayAuth(deviceId: "d1", deviceSecret: "s1"),
            challengeId: "c1",
            approved: true,
            matchDigits: "47"
        )
        #expect(outcome == .failure("That is not the number shown in the browser"))
    }
}
