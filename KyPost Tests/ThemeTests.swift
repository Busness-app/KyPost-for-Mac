//
//  ThemeTests.swift
//  KyPost Tests
//
//  Phase 6 tests: theme palette binding contract (the 13 web theme.ts themes
//  plus the two Ky brand themes), readableOn behavior, ThemeManager
//  persistence, inbox filtering.
//

import Foundation
import SwiftUI
import Testing
@testable import KyPost

// MARK: - Palette contract

@Suite struct ThemePaletteTests {
    @Test func themesMatchWebListPlusKyBrandThemes() {
        // Exact list + order from web THEME_OPTIONS, followed by the two
        // brand-refresh Ky themes.
        #expect(AppTheme.themeNames == [
            "Dark Matter", "Light Matter", "Tropics", "Tropic Night", "Ocean",
            "Coffee", "White Cliffs", "Cyber Punk", "Neon Purple", "Space",
            "Sky", "Forest", "Sun", "Patina Ky", "Polished Ky",
        ])
        #expect(AppTheme.themeNames.count == 15)
        for name in AppTheme.themeNames {
            #expect(AppTheme.palettes[name] != nil, "Missing palette for \(name)")
        }
    }

    @Test func defaultThemeIsPatinaKy() {
        #expect(AppTheme.defaultThemeName == "Patina Ky")
        // Unknown names fall back to the default palette.
        #expect(AppTheme.palette(named: "Nope") == AppTheme.palette(named: "Patina Ky"))
    }

    @Test func spotCheckHexValuesAgainstThemeTs() {
        // Sampled values transcribed from theme.ts — the binding contract.
        #expect(AppTheme.palette(named: "Dark Matter").bg == Color(hex: 0x1A1A1E))
        #expect(AppTheme.palette(named: "Dark Matter").accent == Color(hex: 0xC29A72))
        #expect(AppTheme.palette(named: "Cyber Punk").accent == Color(hex: 0x00F5D4))
        #expect(AppTheme.palette(named: "White Cliffs").panel == Color(hex: 0xFFFFFF))
        #expect(AppTheme.palette(named: "Sun").line == Color(hex: 0xD4B27A))
        #expect(AppTheme.palette(named: "Ocean").accentSoft == Color(hex: 0x214657))
    }

    @Test func lightThemesGetLightColorScheme() {
        // Light themes must run the light system appearance so default text
        // (labels, titles, fields) is dark on their light backgrounds.
        let lightThemes = [
            "Light Matter", "Tropics", "White Cliffs", "Sky", "Sun", "Polished Ky",
        ]
        for name in AppTheme.themeNames {
            let palette = AppTheme.palette(named: name)
            let expected = lightThemes.contains(name)
            #expect(
                palette.isLight == expected,
                "\(name) should be \(expected ? "light" : "dark")"
            )
            #expect(palette.preferredColorScheme == (expected ? .light : .dark))
        }
    }

    @Test func readableOnAccentContrast() {
        #expect(Color(hex: 0xFFFFFF).isPerceptuallyLight)
        #expect(!Color(hex: 0x000000).isPerceptuallyLight)
        // Cyber Punk's bright teal accent needs dark text.
        #expect(Color(hex: 0x00F5D4).isPerceptuallyLight)
        // Ocean's deep accentSoft is dark.
        #expect(!Color(hex: 0x214657).isPerceptuallyLight)
    }
}

// MARK: - ThemeManager

@Suite struct ThemeManagerTests {
    @Test @MainActor func persistsSelectionAndIgnoresUnknownNames() {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!

        let manager = ThemeManager(defaults: defaults)
        #expect(manager.themeName == "Patina Ky")

        manager.setTheme(named: "Ocean")
        #expect(manager.themeName == "Ocean")
        #expect(manager.palette == AppTheme.palette(named: "Ocean"))

        manager.setTheme(named: "Not A Theme")
        #expect(manager.themeName == "Ocean") // unchanged

        // A fresh manager restores the persisted choice.
        let restored = ThemeManager(defaults: defaults)
        #expect(restored.themeName == "Ocean")
    }
}

// MARK: - InboxViewModel filtering

@Suite struct InboxViewModelTests {
    @MainActor
    private func makeViewModel(
        client: HTTPClient,
        initialRefreshErrorDelay: Duration = .seconds(90),
        initialRefreshRetryDelay: Duration = .seconds(15)
    ) throws -> InboxViewModel {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let pairingStore = try makePairedStore()
        let db = try AppDatabase(inMemory: true)
        let mailRepository = MailRepository(
            securePairingStore: pairingStore,
            emailDAO: EmailDAO(modelContainer: db.container),
            httpClient: client
        )
        return InboxViewModel(
            mailRepository: mailRepository,
            keywordRepository: KeywordRepository(
                settingsStore: KeywordSettingsStore(defaults: defaults)
            ),
            initialRefreshErrorDelay: initialRefreshErrorDelay,
            initialRefreshRetryDelay: initialRefreshRetryDelay
        )
    }

    @Test @MainActor func loadBuildsTabsAndFiltersBySelection() async throws {
        let json = """
        {
          "byTab": {
            "Work": [{ "messageId": "1", "subject": "Work thing" }],
            "Important": [{ "messageId": "2", "subject": "Urgent thing" }],
            "": [{ "messageId": "3", "subject": "Untagged thing" }]
          }
        }
        """
        let client = HTTPClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (Data(json.utf8), response)
        }
        let viewModel = try makeViewModel(client: client)

        await viewModel.load()
        #expect(viewModel.emails.count == 3)
        #expect(viewModel.tabs.map(\.name) == ["Important", "Work"])
        #expect(viewModel.errorMessage == nil)

        viewModel.selectedTab = "Work"
        #expect(viewModel.filteredEmails.map(\.serverId) == ["1"])
        viewModel.selectedTab = nil
        #expect(viewModel.filteredEmails.count == 3)
    }

    @Test @MainActor func markReadFlipsFlagsInPlaceAndPostsTheBulkAction() async throws {
        let listJson = """
        {
          "byTab": {
            "": [
              { "messageId": "1", "subject": "a" },
              { "messageId": "2", "subject": "b" }
            ]
          }
        }
        """
        let actionBody = Box("")
        let client = HTTPClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            if request.url!.path.contains("inbox/actions") {
                actionBody.value = request.httpBody.flatMap { String(decoding: $0, as: UTF8.self) } ?? ""
                return (Data(#"{"ok": true}"#.utf8), response)
            }
            return (Data(listJson.utf8), response)
        }
        let viewModel = try makeViewModel(client: client)
        await viewModel.load()
        #expect(viewModel.emails.allSatisfy { !$0.read })

        await viewModel.markRead(serverIds: ["1", "2"])

        // Rows stay in the list with the flag flipped — no removal.
        // (byTab merge order isn't stable, so compare as a set.)
        #expect(Set(viewModel.emails.map(\.serverId)) == ["1", "2"])
        #expect(viewModel.emails.allSatisfy { $0.read })
        #expect(actionBody.value.contains(#""action":"read""#))
        #expect(viewModel.errorMessage == nil)
    }

    @Test @MainActor func notPairedProducesFriendlyError() async throws {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let keychain = KeychainStorage(service: "org.kysecurity.mail.tests.\(UUID().uuidString)")
        let db = try AppDatabase(inMemory: true)
        let viewModel = InboxViewModel(
            mailRepository: MailRepository(
                securePairingStore: SecurePairingStore(keychain: keychain),
                emailDAO: EmailDAO(modelContainer: db.container),
                httpClient: HTTPClient { _ in throw URLError(.badURL) }
            ),
            keywordRepository: KeywordRepository(
                settingsStore: KeywordSettingsStore(defaults: defaults)
            )
        )
        await viewModel.refresh()
        #expect(viewModel.errorMessage?.contains("Pair this device") == true)
    }

    @Test @MainActor func initialTransientRefreshErrorRetriesBeforeAppearing() async throws {
        let attempts = Box(0)
        let client = HTTPClient { request in
            attempts.value += 1
            if attempts.value == 1 { throw URLError(.timedOut) }
            return (
                Data(#"{"byTab":{}}"#.utf8),
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )!
            )
        }
        let viewModel = try makeViewModel(
            client: client,
            initialRefreshErrorDelay: .milliseconds(60),
            initialRefreshRetryDelay: .milliseconds(15)
        )

        await viewModel.load()
        #expect(viewModel.errorMessage == nil)
        try await Task.sleep(for: .milliseconds(40))
        #expect(attempts.value == 2)
        #expect(viewModel.errorMessage == nil)
    }

    @Test @MainActor func persistentInitialErrorAppearsAfterTheGracePeriod() async throws {
        let attempts = Box(0)
        let viewModel = try makeViewModel(
            client: HTTPClient { _ in
                attempts.value += 1
                throw URLError(.timedOut)
            },
            initialRefreshErrorDelay: .milliseconds(60),
            initialRefreshRetryDelay: .milliseconds(15)
        )

        await viewModel.load()
        try await Task.sleep(for: .milliseconds(40))
        #expect(attempts.value == 2)
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.connectionNotice == nil)
        try await Task.sleep(for: .milliseconds(40))
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.connectionNotice == "Unable to connect to the mail server.")
    }

    @Test @MainActor func leavingInboxCancelsItsPendingError() async throws {
        let attempts = Box(0)
        let viewModel = try makeViewModel(
            client: HTTPClient { _ in
                attempts.value += 1
                throw URLError(.timedOut)
            },
            initialRefreshErrorDelay: .milliseconds(60),
            initialRefreshRetryDelay: .milliseconds(15)
        )

        await viewModel.load()
        viewModel.leaveInbox()
        try await Task.sleep(for: .milliseconds(80))

        #expect(attempts.value == 1)
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.connectionNotice == nil)
    }

    @Test @MainActor func manualRefreshFailureUsesSanitizedConnectionNotice() async throws {
        let viewModel = try makeViewModel(
            client: HTTPClient { _ in throw URLError(.cannotConnectToHost) }
        )

        await viewModel.refresh()

        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.connectionNotice == "Unable to connect to the mail server.")
    }

    @Test @MainActor func returningToInboxDoesNotReloadIt() async throws {
        let attempts = Box(0)
        let client = HTTPClient { request in
            attempts.value += 1
            return (
                Data(#"{"byTab":{}}"#.utf8),
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )!
            )
        }
        let viewModel = try makeViewModel(client: client)

        await viewModel.loadIfNeeded()
        viewModel.leaveInbox()
        await viewModel.loadIfNeeded()

        #expect(attempts.value == 1)
        #expect(viewModel.errorMessage == nil)
    }
}
