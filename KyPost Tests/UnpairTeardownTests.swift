//
//  UnpairTeardownTests.swift
//  KyPost Tests
//
//  Unpairing is a session boundary for the OpenPGP key, not only for the
//  pairing credential.
//

import Foundation
import Testing
@testable import KyPost

@MainActor
@Suite struct UnpairTeardownTests {
    private func makeGraph() throws -> SingletonGraph {
        try SingletonGraph(
            userDefaults: UserDefaults(suiteName: "tests.\(UUID().uuidString)")!,
            keychain: KeychainStorage(service: "com.urlxl.mail.tests.\(UUID().uuidString)"),
            database: AppDatabase(inMemory: true)
        )
    }

    /// Built on a mock contact store rather than `graph.systemContactsExporter`,
    /// whose live store reads the real Contacts database of whoever runs the
    /// suite.
    private func makeViewModel(_ graph: SingletonGraph) -> SettingsViewModel {
        let store = MockSystemContactStore()
        let exporter = SystemContactsExporter(
            store: store,
            linkStore: graph.systemContactsLinkStore,
            baselineStore: graph.systemContactsBaselineStore,
            settings: graph.contactsSettingsStore,
            contactDAO: graph.contactDAO,
            photoCache: graph.contactPhotoCache,
            groupLinker: SystemContactGroupLinker(
                store: store,
                linkStore: graph.systemContactGroupLinkStore
            ),
            groupDAO: graph.groupDAO
        )
        return SettingsViewModel(
            securePairingStore: graph.securePairingStore,
            pushSettingsStore: graph.pushSettingsStore,
            desktopSessionStore: graph.desktopSessionStore,
            mailRepository: graph.mailRepository,
            keywordRepository: graph.keywordRepository,
            contactsSettingsStore: graph.contactsSettingsStore,
            systemContactsExporter: exporter,
            deviceRegistrationService: graph.deviceRegistrationService,
            deregisterDeviceUseCase: graph.deregisterDeviceUseCase,
            pushNotificationDispatcher: graph.pushNotificationDispatcher,
            enrollmentVault: graph.enrollmentVault
        )
    }

    /// The envelope is the account's private key sealed to *this* Mac. Left
    /// behind, it outlives the pairing that authorised putting it here — on a
    /// machine the account no longer knows about, so no revocation reaches it.
    @Test func unpairingDestroysTheSealedEnvelope() async throws {
        let graph = try makeGraph()
        try graph.enrollmentVault.store(
            privateKey: Data("-----BEGIN PGP PRIVATE KEY BLOCK-----".utf8),
            identityFingerprint: "AABBCCDDEEFF00112233445566778899AABBCCDD"
        )
        #expect(graph.enrollmentVault.isEnrolled)

        await makeViewModel(graph).unpair()
        #expect(!graph.enrollmentVault.isEnrolled)
    }

    /// Destroying the sealed blob while an unsealed copy sits in this process
    /// would be theatre — the plaintext key is the thing that matters.
    @Test func unpairingDropsTheUnsealedCopyToo() async throws {
        let graph = try makeGraph()
        EnrollmentSession.shared.put(armoredKey: "-----BEGIN PGP PRIVATE KEY BLOCK-----")
        #expect(EnrollmentSession.shared.isHeld)

        await makeViewModel(graph).unpair()
        #expect(!EnrollmentSession.shared.isHeld)
    }
}
