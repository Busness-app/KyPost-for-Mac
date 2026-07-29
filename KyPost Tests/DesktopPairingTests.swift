//
//  DesktopPairingTests.swift
//  KyPost Tests
//
//  Desktop Pairing guide tests: deep-link parsing, endpoint derivation, code
//  format validation, and register outcome mapping via a stub transport.
//

import Foundation
import Testing
@testable import KyPost

// MARK: - Helpers


/// Sample code from the guide (32 chars, alphanumeric).
private let validCode = "A1B2C3D4E5F6G7H8I9J0K1L2M3N4O5P6"
private let validDesktopLink = URL(
    string: "kypost://desktop-pair?code=\(validCode)&srv=https://relay.example.com"
)!

// MARK: - Register dedupe (one registration per code)

@MainActor
@Suite struct DesktopPairingServiceDedupeTests {
    private func makeService(counter: Box<Int>) -> DesktopPairingService {
        let json = """
        {"ok": true, "sessionToken": "jwt-token", "expiresIn": 86400, \
        "userId": "u1", "userEmail": "user@example.com"}
        """
        let client = HTTPClient { request in
            counter.mutate { $0 += 1 }
            try? await Task.sleep(for: .milliseconds(10))
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(json.utf8), response)
        }
        return DesktopPairingService(
            client: DesktopRegistrationClient(httpClient: client),
            sessionStore: DesktopSessionStore(
                keychain: KeychainStorage(service: "com.urlxl.mail.tests.\(UUID().uuidString)")
            )
        )
    }

    private var params: DesktopPairingParams {
        DesktopPairingParams(code: validCode, srv: "https://relay.example.com")
    }

    /// The deep link is delivered to every open window and each auto-pairs;
    /// concurrent calls with one code must collapse into one registration.
    @Test func concurrentPairsWithSameCodeRegisterOnce() async {
        let counter = Box<Int>(0)
        let service = makeService(counter: counter)
        async let first = service.pair(params: params)
        async let second = service.pair(params: params)
        let outcomes = await [first, second]
        #expect(counter.value == 1)
        let expected = DesktopRegistrationOutcome.success(DesktopRegistrationResponse(
            ok: true, sessionToken: "jwt-token", expiresIn: 86400,
            userId: "u1", userEmail: "user@example.com"
        ))
        #expect(outcomes == [expected, expected])
    }

    @Test func repeatPairWithSameCodeReusesOutcome() async {
        let counter = Box<Int>(0)
        let service = makeService(counter: counter)
        let first = await service.pair(params: params)
        let second = await service.pair(params: params)
        #expect(counter.value == 1)
        #expect(first == second)
    }
}

// MARK: - DesktopPairingViewModel confirmation flow (pairing-hijack fix)

@MainActor
@Suite struct DesktopPairingViewModelTests {
    private func makeViewModel(existingSession: Bool = false) throws -> DesktopPairingViewModel {
        let keychain = KeychainStorage(service: "com.urlxl.mail.tests.\(UUID().uuidString)")
        let sessionStore = DesktopSessionStore(keychain: keychain)
        if existingSession {
            try sessionStore.saveSession(DesktopSession(
                sessionToken: "old-token",
                expiresAt: Date(timeIntervalSinceNow: 86_400),
                userId: "u1",
                userEmail: "user@example.com",
                srv: server,
                pairedAt: Date()
            ))
        }
        return DesktopPairingViewModel(
            pairingService: DesktopPairingService(
                client: DesktopRegistrationClient(httpClient: stubClient()),
                sessionStore: sessionStore
            ),
            sessionStore: sessionStore
        )
    }

    private var params: DesktopPairingParams { DesktopPairingParams(code: validCode, srv: server) }

    @Test func presentShowsTheDestinationHostBeforeAnyNetworkCall() throws {
        let viewModel = try makeViewModel(existingSession: false)
        viewModel.present(params: params)
        #expect(viewModel.state == .confirming(
            PendingDesktopPairingConfirmation(params: params, existingHost: nil)
        ))
    }

    @Test func presentWarnsWhenAcceptingWouldReplaceAnExistingSession() throws {
        let viewModel = try makeViewModel(existingSession: true)
        viewModel.present(params: params)
        #expect(viewModel.state == .confirming(
            PendingDesktopPairingConfirmation(params: params, existingHost: URL(string: server)?.host)
        ))
    }

    @Test func pairFromPastedLinkAsksForConfirmationInsteadOfPairingImmediately() async throws {
        let viewModel = try makeViewModel()
        viewModel.pastedLink = "kypost://desktop-pair?code=\(validCode)&srv=\(server)"
        await viewModel.pairFromPastedLink()
        guard case .confirming(let confirmation) = viewModel.state else {
            Issue.record("Expected .confirming, got \(viewModel.state)")
            return
        }
        #expect(confirmation.params == params)
    }

    @Test func confirmingThenPairStillCompletesRegistration() async throws {
        let keychain = KeychainStorage(service: "com.urlxl.mail.tests.\(UUID().uuidString)")
        let sessionStore = DesktopSessionStore(keychain: keychain)
        let json = """
        {"ok": true, "sessionToken": "jwt-token", "expiresIn": 86400, \
        "userId": "u1", "userEmail": "user@example.com"}
        """
        let viewModel = DesktopPairingViewModel(
            pairingService: DesktopPairingService(
                client: DesktopRegistrationClient(httpClient: stubClient(json: json)),
                sessionStore: sessionStore
            ),
            sessionStore: sessionStore
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

// MARK: - Deep-link parsing

@Suite struct DesktopPairingLinkParserTests {
    @Test func parsesValidLink() throws {
        let params = try DesktopPairingLinkParser.parse(validDesktopLink)
        #expect(params.code == validCode)
        #expect(params.srv == "https://relay.example.com")
    }

    @Test(arguments: ["code", "srv"])
    func rejectsMissingRequiredParameter(missing: String) {
        let all = ["code": validCode, "srv": "https://s.example.com"]
        let query = all
            .filter { $0.key != missing }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
        let url = URL(string: "kypost://desktop-pair?\(query)")!
        #expect(throws: PairingLinkError.missingParameter(missing)) {
            try DesktopPairingLinkParser.parse(url)
        }
    }

    @Test func rejectsWrongSchemeOrHost() {
        let wrongScheme = URL(string: "https://desktop-pair?code=c&srv=s")!
        let wrongHost = URL(string: "kypost://native-pair?code=c&srv=s")!
        #expect(throws: PairingLinkError.notAPairingLink) {
            try DesktopPairingLinkParser.parse(wrongScheme)
        }
        #expect(throws: PairingLinkError.notAPairingLink) {
            try DesktopPairingLinkParser.parse(wrongHost)
        }
    }

    /// A crafted link pointing `srv` at a plaintext host must be rejected.
    @Test func rejectsNonHttpsServerURL() {
        let url = URL(string: "kypost://desktop-pair?code=\(validCode)&srv=http://relay.example.com")!
        #expect(throws: PairingLinkError.insecureServerURL) {
            try DesktopPairingLinkParser.parse(url)
        }
    }

    @Test func deepLinkHandlerRoutesDesktopPairingLinks() throws {
        let handler = DeepLinkHandler()
        let expected = NavigationAction.openDesktopPairingFlow(
            try DesktopPairingLinkParser.parse(validDesktopLink)
        )
        #expect(handler.handle(validDesktopLink) == expected)
    }

    @Test func registerEndpointDerivedFromSrv() {
        let params = DesktopPairingParams(code: validCode, srv: "https://relay.example.com")
        #expect(
            params.registerEndpoint?.absoluteString
            == "https://relay.example.com/api/notifications/desktop/register"
        )
    }
}

// MARK: - Code format validation (guide checklist)

@Suite struct DesktopPairingCodeValidationTests {
    @Test func acceptsGuideSampleCode() {
        #expect(DesktopPairingService.isValidCode(validCode))
    }

    @Test(arguments: [
        "",
        "SHORT",
        "A1B2C3D4E5F6G7H8I9J0K1L2M3N4O5P6EXTRA",
        "A1B2C3D4E5F6G7H8I9J0K1L2M3N4O5P!",
    ])
    func rejectsMalformedCodes(code: String) {
        #expect(!DesktopPairingService.isValidCode(code))
    }
}

// MARK: - Register outcome mapping

@Suite struct DesktopRegistrationClientTests {
    private let params = DesktopPairingParams(code: validCode, srv: "https://relay.example.com")

    @Test func successSendsCodeAndDecodesSession() async {
        let json = """
        {
          "ok": true,
          "sessionToken": "jwt-token",
          "expiresIn": 86400,
          "userId": "user123",
          "userEmail": "user@example.com"
        }
        """
        let client = stubClient(status: 200, json: json) { request in
            #expect(
                request.url!.absoluteString
                == "https://relay.example.com/api/notifications/desktop/register"
            )
            #expect(request.httpMethod == "POST")
            let body = request.httpBody.flatMap { String(decoding: $0, as: UTF8.self) } ?? ""
            #expect(body.contains(#""pairingCode":"\#(validCode)""#))
            #expect(body.contains("appName"))
            #expect(body.contains("appVersion"))
            #expect(body.contains("platformInfo"))
        }
        let outcome = await DesktopRegistrationClient(httpClient: client).register(params: params)
        guard case .success(let response) = outcome else {
            Issue.record("Expected success, got \(outcome)")
            return
        }
        #expect(response.sessionToken == "jwt-token")
        #expect(response.expiresIn == 86400)
        #expect(response.userId == "user123")
        #expect(response.userEmail == "user@example.com")
    }

    @Test func invalidOrExpiredCodeIs401() async {
        let outcome = await DesktopRegistrationClient(httpClient: stubClient(status: 401))
            .register(params: params)
        #expect(outcome == .invalidOrExpiredCode)
    }

    @Test func consumedCodeIs409() async {
        let outcome = await DesktopRegistrationClient(httpClient: stubClient(status: 409))
            .register(params: params)
        #expect(outcome == .codeAlreadyConsumed)
    }

    @Test func rateLimitedIs429() async {
        let outcome = await DesktopRegistrationClient(httpClient: stubClient(status: 429))
            .register(params: params)
        #expect(outcome == .rateLimited)
    }

    @Test func rateLimitStatusMapping() {
        #expect(NetworkError.from(statusCode: 429) == .rateLimited)
    }
}

// MARK: - The memo does not outlive the code

/// `completed` was an unbounded map, keyed by pairing code, holding every
/// attempt's outcome — and the account email it resolved to — for the process
/// lifetime. Codes are single-use with a 5-minute TTL, so there is nothing to
/// remember past that.
@MainActor
@Suite struct DesktopPairingMemoExpiryTests {
    private func makeService(counter: Box<Int>, clock: Box<Date>) -> DesktopPairingService {
        let json = """
        {"ok": true, "sessionToken": "jwt-token", "expiresIn": 86400, \
        "userId": "u1", "userEmail": "user@example.com"}
        """
        let client = HTTPClient { request in
            counter.mutate { $0 += 1 }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (Data(json.utf8), response)
        }
        return DesktopPairingService(
            client: DesktopRegistrationClient(httpClient: client),
            sessionStore: DesktopSessionStore(
                keychain: KeychainStorage(service: "com.urlxl.mail.tests.\(UUID().uuidString)")
            ),
            now: { clock.value }
        )
    }

    private var params: DesktopPairingParams {
        DesktopPairingParams(code: validCode, srv: "https://relay.example.com")
    }

    @Test func aMemoWithinTheTTLIsStillReused() async {
        let counter = Box<Int>(0)
        let clock = Box(Date(timeIntervalSince1970: 0))
        let service = makeService(counter: counter, clock: clock)
        _ = await service.pair(params: params)
        clock.mutate { $0 = $0.addingTimeInterval(60) }
        _ = await service.pair(params: params)
        #expect(counter.value == 1)
    }

    /// Past the TTL the server would answer differently, so the memo must not.
    @Test func anExpiredMemoIsDropped() async {
        let counter = Box<Int>(0)
        let clock = Box(Date(timeIntervalSince1970: 0))
        let service = makeService(counter: counter, clock: clock)
        _ = await service.pair(params: params)
        clock.mutate { $0 = $0.addingTimeInterval(10 * 60) }
        _ = await service.pair(params: params)
        #expect(counter.value == 2)
    }
}
