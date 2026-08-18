//
//  SingletonGraph.swift
//  KyPost
//
//  Dependency injection container (spec §Architecture). The app uses `.shared`;
//  tests build their own instance with an in-memory database and scratch
//  UserDefaults suite.
//

import Foundation
import os

@MainActor
final class SingletonGraph {
    /// The current graph. An alias into AppEnvironment so Hostile Location
    /// Protection can swap the graph wholesale — re-read this per use;
    /// never capture it (or a child) into long-lived state outside the
    /// .id(generation)-scoped view trees.
    static var shared: SingletonGraph { AppEnvironment.shared.graph }

    // MARK: - Data

    let database: AppDatabase
    let keychain: KeychainStorage

    // MARK: - Storage

    let appLockStore: AppLockStore
    let hostileLocationProtectionStore: HostileLocationProtectionStore
    let securePairingStore: SecurePairingStore
    let keywordSettingsStore: KeywordSettingsStore
    let notificationCursorStore: NotificationCursorStore
    let contactCursorStore: ContactCursorStore
    let verifiedPgpKeyStore: VerifiedPgpKeyStore
    let contactPendingDeletesStore: ContactPendingDeletesStore
    let contactsSettingsStore: ContactsSettingsStore
    let systemContactsLinkStore: SystemContactsLinkStore
    let systemContactsBaselineStore: SystemContactsBaselineStore
    let pushSettingsStore: PushSettingsStore
    let desktopSessionStore: DesktopSessionStore

    // MARK: - DAOs

    lazy var emailDAO = EmailDAO(modelContainer: database.container)
    lazy var contactDAO = ContactDAO(modelContainer: database.container)
    lazy var pushNotificationDAO = PushNotificationDAO(modelContainer: database.container)

    // MARK: - Networking

    /// TOFU pinning (security-hardening plan, Task 9): enforce the pinned
    /// SPKI only for the paired relay's host — scanned foreign key-exchange
    /// URLs keep default TLS handling. Reads go straight to KeychainStorage
    /// because the delegate runs off the main actor.
    lazy var pinnedSessionDelegate = PinnedSessionDelegate { [keychain] host in
        guard
            let pin = try? keychain.string(forKey: SecurePairingStore.pinnedSpkiHashKey),
            !pin.isEmpty,
            let srv = try? keychain.string(forKey: SecurePairingStore.srvKey),
            let relayHost = URL(string: srv)?.host(),
            relayHost.caseInsensitiveCompare(host) == .orderedSame
        else { return nil }
        return pin
    }
    /// Held rather than captured so `shutdown()` can invalidate it: a
    /// delegate-backed URLSession retains its delegate and its connection pool
    /// until invalidated, so without this a superseded graph would keep live
    /// TLS connections to the relay open — exactly what enabling Hostile
    /// Location Protection is asking us to tear down.
    lazy var relaySession = URLSession(
        configuration: .default, delegate: pinnedSessionDelegate, delegateQueue: nil
    )
    lazy var httpClient: HTTPClient = {
        let delegate = pinnedSessionDelegate
        let session = relaySession
        // Scoped to this request's host: an unrelated cancellation must not
        // inherit another host's mismatch (and vice versa).
        let mapPinFailure: @Sendable (URLRequest, Error) -> Error = { request, error in
            guard let urlError = error as? URLError, urlError.code == .cancelled,
                  delegate.pinFailed(forHost: request.url?.host() ?? "")
            else { return error }
            return NetworkError.certificateMismatch
        }
        // Both seams, not just the buffering one: attachment downloads go
        // through the streaming transport, and building this from the
        // single-transport initializer left them on the uncapped fallback.
        let streaming = HTTPClient.streamTransport(session: session)
        return HTTPClient(
            transport: { request in
                do {
                    return try await session.data(for: request)
                } catch {
                    throw mapPinFailure(request, error)
                }
            },
            streamTransport: { request, limit in
                do {
                    return try await streaming(request, limit)
                } catch {
                    throw mapPinFailure(request, error)
                }
            }
        )
    }()
    lazy var nativeRegistrationClient = NativeRegistrationClient(httpClient: httpClient)
    lazy var desktopRegistrationClient = DesktopRegistrationClient(httpClient: httpClient)
    lazy var pushNotificationClient = PushNotificationClient(httpClient: httpClient)
    lazy var mfaResponseClient = MfaResponseClient(httpClient: httpClient)
    lazy var deregisterClient = DeregisterClient(httpClient: httpClient)
    lazy var contactSyncClient = ContactSyncClient(httpClient: httpClient)
    lazy var pgpQrClient = PgpQrClient(httpClient: httpClient)
    lazy var pgpSendClient = PgpSendClient(httpClient: httpClient)

    // MARK: - Repositories & Use Cases

    lazy var mailCursorStore = MailCursorStore(
        defaults: userDefaults,
        hostileLocation: hostileLocationProtectionStore
    )
    lazy var mailRepository = MailRepository(
        securePairingStore: securePairingStore,
        emailDAO: emailDAO,
        httpClient: httpClient,
        cursorStore: mailCursorStore
    )
    lazy var keywordRepository = KeywordRepository(settingsStore: keywordSettingsStore)
    lazy var sendEmailUseCase = SendEmailUseCase(repository: mailRepository)
    lazy var pgpSendService = PgpSendService(
        client: pgpSendClient,
        securePairingStore: securePairingStore
    )
    let contactPhotoCache: ContactPhotoCache
    lazy var systemContactsExporter = SystemContactsExporter(
        store: LiveSystemContactStore(),
        linkStore: systemContactsLinkStore,
        baselineStore: systemContactsBaselineStore,
        settings: contactsSettingsStore,
        contactDAO: contactDAO,
        photoCache: contactPhotoCache
    )
    lazy var systemContactsChangeMonitor = SystemContactsChangeMonitor(
        exporter: systemContactsExporter,
        repository: contactSyncRepository
    )
    lazy var contactSyncRepository = ContactSyncRepository(
        client: contactSyncClient,
        contactDAO: contactDAO,
        cursorStore: contactCursorStore,
        pendingDeletesStore: contactPendingDeletesStore,
        securePairingStore: securePairingStore,
        systemContactsExporter: systemContactsExporter,
        photoCache: contactPhotoCache,
        verifiedKeyStore: verifiedPgpKeyStore,
        groupsClient: groupsSyncClient,
        groupDAO: groupDAO
    )
    lazy var groupsSyncClient = GroupsSyncClient(httpClient: httpClient)
    lazy var groupDAO = GroupDAO(modelContainer: database.container)
    lazy var pushRepository = PushRepository(
        dao: pushNotificationDAO,
        cursorStore: notificationCursorStore,
        client: pushNotificationClient,
        securePairingStore: securePairingStore,
        pushSettingsStore: pushSettingsStore
    )
    lazy var approveMfaChallengeUseCase = ApproveMfaChallengeUseCase(
        client: mfaResponseClient,
        securePairingStore: securePairingStore
    )
    lazy var deregisterDeviceUseCase = DeregisterDeviceUseCase(
        client: deregisterClient,
        securePairingStore: securePairingStore
    )
    lazy var deviceRegistrationService: DeviceRegistrationService = {
        let service = DeviceRegistrationService(
            client: nativeRegistrationClient,
            securePairingStore: securePairingStore,
            pushSettingsStore: pushSettingsStore
        )
        // TOFU: a successful pairing persists the SPKI hash its handshake
        // presented (see PinnedSessionDelegate).
        service.observedSpkiHash = { [pinnedSessionDelegate] host in
            pinnedSessionDelegate.lastSeenHash(forHost: host)
        }
        // …and when the registration rode a pooled or resumed connection so no
        // handshake was ever observed, force one rather than leaving the pin
        // silently unarmed.
        service.probeSpkiHash = { [pinnedSessionDelegate] url in
            await PinnedSessionDelegate.probeHash(url: url, delegate: pinnedSessionDelegate)
        }
        return service
    }()
    lazy var desktopPairingService = DesktopPairingService(
        client: desktopRegistrationClient,
        sessionStore: desktopSessionStore
    )

    // MARK: - Notifications

    lazy var pushNotificationDispatcher = PushNotificationDispatcher(
        pushRepository: pushRepository,
        approveMfaChallenge: approveMfaChallengeUseCase,
        pushSettingsStore: pushSettingsStore
    )
    lazy var pullPollingScheduler = PullPollingScheduler(
        pushRepository: pushRepository,
        pushSettingsStore: pushSettingsStore,
        dispatcher: pushNotificationDispatcher
    )

    // MARK: - View Models (shared so menu commands and views stay in sync)

    lazy var inboxViewModel = InboxViewModel(
        mailRepository: mailRepository,
        keywordRepository: keywordRepository
    )
    lazy var contactsViewModel = ContactsViewModel(repository: contactSyncRepository)

    // MARK: - Security

    lazy var appLockManager = AppLockManager(store: appLockStore)
    lazy var credentialGateService = CredentialGateService(
        appLockStore: appLockStore,
        securePairingStore: securePairingStore,
        gatedStore: GatedCredentialStore(),
        lockManager: appLockManager
    )

    // MARK: - Lifecycle

    /// Stops every long-lived task this graph owns, so a superseded graph
    /// can't keep polling or writing to its database after
    /// AppEnvironment.rebuild swaps it out. Touching the lazy vars may
    /// construct them first — harmless, a freshly built scheduler/monitor
    /// stops as a no-op.
    func shutdown() {
        pullPollingScheduler.stopForegroundPolling()
        systemContactsChangeMonitor.stop()
        inboxViewModel.stopAutoRefresh()
        // Drops in-flight requests, the connection pool, and the session's
        // strong reference to its delegate. Not `finishTasksAndInvalidate`:
        // a superseded graph's requests write to a database that is going
        // away, and the Hostile Location Protection case wants them gone now.
        relaySession.invalidateAndCancel()
    }

    // MARK: - Startup migrations

    private static let legacyContactFieldsMigratedKey = "contacts.legacyFieldsMigrated"
    private static let reconciliationRepairKey = "contacts.reconciliationRepair.v1"
    private static let systemImportDupeRepairKey = "contacts.systemImportDupeRepair.v1"
    private let userDefaults: UserDefaults

    /// One-time data backfills after schema migrations (the V1→V2 legacy
    /// email/phone → arrays copy, and the cleanup of rows duplicated by the
    /// old order-based reconciler). Safe to call every launch.
    func runStartupMigrationsIfNeeded() async {
        if !userDefaults.bool(forKey: Self.legacyContactFieldsMigratedKey) {
            do {
                try await contactDAO.migrateLegacyFields()
                userDefaults.set(true, forKey: Self.legacyContactFieldsMigratedKey)
            } catch {
                Log.sync.error("Contact legacy-field backfill failed: \(error.localizedDescription)")
            }
        }
        if !userDefaults.bool(forKey: Self.reconciliationRepairKey) {
            do {
                try await contactDAO.repairReconciliationArtifacts()
                userDefaults.set(true, forKey: Self.reconciliationRepairKey)
            } catch {
                Log.sync.error("Contact reconciliation repair failed: \(error.localizedDescription)")
            }
        }
        if !userDefaults.bool(forKey: Self.systemImportDupeRepairKey) {
            do {
                let removed = try await contactDAO.repairImportedDuplicates()
                // The links and baseline reference drifted card identifiers;
                // forgetting both makes the next reconcile recapture the
                // baseline and re-adopt cards by identity instead of
                // re-importing or deleting anything.
                systemContactsLinkStore.clear()
                systemContactsBaselineStore.clear()
                userDefaults.set(true, forKey: Self.systemImportDupeRepairKey)
                if removed > 0 {
                    Log.sync.info("Removed \(removed) duplicate imported contacts")
                }
            } catch {
                Log.sync.error("Contact import-dupe repair failed: \(error.localizedDescription)")
            }
        }
    }

    init(
        userDefaults: UserDefaults = .standard,
        keychain: KeychainStorage = KeychainStorage(),
        database: AppDatabase? = nil
    ) throws {
        self.userDefaults = userDefaults
        hostileLocationProtectionStore = HostileLocationProtectionStore(defaults: userDefaults)
        let hostileLocation = hostileLocationProtectionStore.enabled

        // Hostile Location Protection keeps the whole cache in memory.
        self.database = try database ?? AppDatabase(inMemory: hostileLocation)
        contactPhotoCache = ContactPhotoCache(inMemory: hostileLocation)
        if !self.database.isInMemory {
            do {
                try AppDatabase.excludeStoreFromBackup()
            } catch {
                Log.storage.error("Could not exclude the store from backup: \(error.localizedDescription)")
            }
        }
        self.keychain = keychain
        appLockStore = AppLockStore(keychain: keychain)
        securePairingStore = SecurePairingStore(keychain: keychain)
        keywordSettingsStore = KeywordSettingsStore(defaults: userDefaults)
        notificationCursorStore = NotificationCursorStore(defaults: userDefaults)
        contactCursorStore = ContactCursorStore(defaults: userDefaults)
        contactPendingDeletesStore = ContactPendingDeletesStore(defaults: userDefaults)
        verifiedPgpKeyStore = VerifiedPgpKeyStore(defaults: userDefaults)
        contactsSettingsStore = ContactsSettingsStore(defaults: userDefaults)
        systemContactsLinkStore = SystemContactsLinkStore(defaults: userDefaults)
        systemContactsBaselineStore = SystemContactsBaselineStore(defaults: userDefaults)
        pushSettingsStore = PushSettingsStore(defaults: userDefaults)
        desktopSessionStore = DesktopSessionStore(keychain: keychain)
    }
}
