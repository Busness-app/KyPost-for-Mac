//
//  SecurityTests.swift
//  KyPost Tests
//
//  Security-hardening Task 1: AppLockStore flag persistence and
//  AppLockManager lock/unlock/toggle behavior, with LAContext stubbed
//  behind DeviceAuthenticating.
//

import Foundation
import Testing
@testable import KyPost

/// Closure-driven stand-in for LAContext, which cannot run headless.
/// Counts authenticate calls so tests can pin when re-auth is required.
private struct StubAuthenticator: DeviceAuthenticating {
    var canAuth = true
    var authResult = true
    let authenticateCalls = Box(0)

    func canAuthenticate() -> Bool { canAuth }

    func authenticate(reason: String) async -> Bool {
        authenticateCalls.mutate { $0 += 1 }
        return authResult
    }
}

private func makeLockStore() -> AppLockStore {
    AppLockStore(keychain: KeychainStorage(service: "com.urlxl.mail.tests.\(UUID().uuidString)"))
}

// MARK: - AppLockStore

@Suite struct AppLockStoreTests {
    @Test func flagsDefaultToFalseAndRoundTrip() throws {
        let store = makeLockStore()
        #expect(!store.lockEnabled)
        #expect(!store.credentialGateEnabled)

        try store.setLockEnabled(true)
        try store.setCredentialGateEnabled(true)
        #expect(store.lockEnabled)
        #expect(store.credentialGateEnabled)

        try store.setLockEnabled(false)
        #expect(!store.lockEnabled)
        // The two flags are independent items.
        #expect(store.credentialGateEnabled)
    }
}

// MARK: - Hostile Location Protection (Task 5)

@Suite struct HostileLocationProtectionTests {
    @Test func storeFlagRoundTrips() {
        let store = HostileLocationProtectionStore(
            defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        )
        #expect(!store.enabled)
        store.enabled = true
        #expect(store.enabled)
        store.enabled = false
        #expect(!store.enabled)
    }

    @Test func deleteStoreFilesRemovesTheSqliteTrio() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "storewipe.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appending(path: "default.store")
        for suffix in ["", "-wal", "-shm"] {
            FileManager.default.createFile(
                atPath: store.path + suffix, contents: Data("x".utf8)
            )
        }

        try AppDatabase.deleteStoreFiles(at: store)

        for suffix in ["", "-wal", "-shm"] {
            #expect(!FileManager.default.fileExists(atPath: store.path + suffix))
        }
        // Deleting again with nothing there is not an error.
        try AppDatabase.deleteStoreFiles(at: store)
    }

    @Test @MainActor func graphBuildsInMemoryWhenTheFlagIsSet() throws {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        HostileLocationProtectionStore(defaults: defaults).enabled = true

        let graph = try SingletonGraph(
            userDefaults: defaults,
            keychain: KeychainStorage(service: "com.urlxl.mail.tests.\(UUID().uuidString)")
        )

        #expect(graph.database.isInMemory)
    }

    @Test @MainActor func purgeRemovesTheAttachmentStagingArea() throws {
        let root = InboxViewModel.attachmentTempRoot
        let file = root.appending(path: "m-1/0/report.pdf")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8))

        InboxViewModel.purgeAttachmentTempFiles()

        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}

// MARK: - AppLockManager

@MainActor
@Suite struct AppLockManagerTests {
    @Test func startsUnlockedWhenTheFeatureIsOff() {
        let manager = AppLockManager(store: makeLockStore(), authenticator: StubAuthenticator())
        #expect(!manager.isLocked)
    }

    @Test func startsLockedWhenTheFeatureIsOn() throws {
        let store = makeLockStore()
        try store.setLockEnabled(true)
        let manager = AppLockManager(store: store, authenticator: StubAuthenticator())
        #expect(manager.isLocked)
    }

    @Test func lockIsANoOpWhileTheFeatureIsOff() {
        let manager = AppLockManager(store: makeLockStore(), authenticator: StubAuthenticator())
        manager.lock()
        #expect(!manager.isLocked)
    }

    @Test func successfulUnlockClearsTheLockAndFiresOnUnlock() async throws {
        let store = makeLockStore()
        try store.setLockEnabled(true)
        let manager = AppLockManager(store: store, authenticator: StubAuthenticator())
        let unlocked = Box(0)
        manager.onUnlock = { unlocked.mutate { $0 += 1 } }

        #expect(await manager.requestUnlock())
        #expect(!manager.isLocked)
        #expect(unlocked.value == 1)

        // Already unlocked: succeeds without another prompt.
        #expect(await manager.requestUnlock())
        #expect(unlocked.value == 1)
    }

    @Test func failedUnlockStaysLocked() async throws {
        let store = makeLockStore()
        try store.setLockEnabled(true)
        let manager = AppLockManager(
            store: store,
            authenticator: StubAuthenticator(authResult: false)
        )
        #expect(await !manager.requestUnlock())
        #expect(manager.isLocked)
    }

    @Test func relockFiresOnLockAndUnlockPromptsAgain() async throws {
        let store = makeLockStore()
        try store.setLockEnabled(true)
        let stub = StubAuthenticator()
        let manager = AppLockManager(store: store, authenticator: stub)
        let locked = Box(0)
        manager.onLock = { locked.mutate { $0 += 1 } }

        _ = await manager.requestUnlock()
        manager.lock()
        #expect(manager.isLocked)
        #expect(locked.value == 1)
        // Locking again while already locked does not re-fire.
        manager.lock()
        #expect(locked.value == 1)

        _ = await manager.requestUnlock()
        #expect(stub.authenticateCalls.value == 2)
    }

    @Test func enablingIsRefusedWithoutDeviceAuthentication() async {
        let store = makeLockStore()
        let manager = AppLockManager(
            store: store,
            authenticator: StubAuthenticator(canAuth: false)
        )
        #expect(await !manager.setLockEnabled(true))
        #expect(!store.lockEnabled)
    }

    @Test func enablingDoesNotLockTheRunningSession() async {
        let store = makeLockStore()
        let manager = AppLockManager(store: store, authenticator: StubAuthenticator())
        #expect(await manager.setLockEnabled(true))
        #expect(store.lockEnabled)
        #expect(!manager.isLocked)
        // …but the next trigger locks.
        manager.lock()
        #expect(manager.isLocked)
    }

    @Test func disablingRequiresReauthentication() async throws {
        let store = makeLockStore()
        try store.setLockEnabled(true)

        let refused = AppLockManager(
            store: store,
            authenticator: StubAuthenticator(authResult: false)
        )
        #expect(await !refused.setLockEnabled(false))
        #expect(store.lockEnabled)
        #expect(refused.isLocked)

        let allowed = AppLockManager(store: store, authenticator: StubAuthenticator())
        #expect(await allowed.setLockEnabled(false))
        #expect(!store.lockEnabled)
        #expect(!allowed.isLocked)
    }
}
