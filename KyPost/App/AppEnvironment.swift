//
//  AppEnvironment.swift
//  KyPost
//
//  Reconstructable holder for the dependency graph (security-hardening
//  plan, Task 4). SingletonGraph.shared aliases the current graph, so the
//  rest of the app keeps compiling unchanged — the rule is that call sites
//  must re-read .shared per use, never capture a graph child into
//  long-lived state outside the .id(generation)-scoped view trees.
//
//  Rebuilding is how Hostile Location Protection swaps between the
//  disk-backed and in-memory databases: every scene root is keyed on
//  `generation`, so a bump tears down the entire view tree, including all
//  view models holding old DAO references.
//

import Foundation
import Observation
import os
import UserNotifications

extension Notification.Name {
    /// Posted when Hostile Location Protection is toggled. The compose scene
    /// observes it and dismisses: `dismissWindow` is a SwiftUI environment
    /// value available only inside a View, so it can't be called from here.
    static let kyPostCloseComposeWindows = Notification.Name("kypost.closeComposeWindows")
}

@Observable
@MainActor
final class AppEnvironment {
    /// A `ModelContainer` that will not open — a corrupt store, a migration
    /// that failed, a full disk — used to crash the app on launch, forever,
    /// with a crash log the user could do nothing about. Mail lives on the
    /// server and the local store is a disposable cache, so discarding it is
    /// the obviously correct response; in-memory is the last resort so the app
    /// still opens and can be re-paired.
    static let shared = AppEnvironment(graph: makeLaunchGraph())

    private static func makeLaunchGraph() -> SingletonGraph {
        do {
            return try SingletonGraph()
        } catch {
            Log.storage.error("Local store unusable, recreating it: \(error.localizedDescription)")
        }
        try? AppDatabase.deleteStoreFiles()
        do {
            return try SingletonGraph()
        } catch {
            Log.storage.error(
                "Could not recreate the local store, running without one: \(error.localizedDescription)"
            )
        }
        do {
            return try SingletonGraph(database: AppDatabase(inMemory: true))
        } catch {
            // An in-memory SwiftData container failing means the schema itself
            // is invalid — a programmer error no user action can resolve.
            fatalError("Could not build an in-memory dependency graph: \(error)")
        }
    }

    private(set) var graph: SingletonGraph
    /// Keyed into every scene root via .id(generation).
    private(set) var generation = 0

    /// Re-runs the launch wiring (notification delegate, contact monitor,
    /// foreground sync) after a rebuild. Set by AppDelegate at launch; nil
    /// in tests, where no runtime services should start.
    var onRebuild: (() -> Void)?

    init(graph: SingletonGraph) {
        self.graph = graph
    }

    /// Swaps the whole graph. The new graph is built before the old one is
    /// shut down, so a failed rebuild leaves the running app untouched; the
    /// shutdown ensures nothing keeps polling or writing to the superseded
    /// database on a timer.
    func rebuild(makeGraph: () throws -> SingletonGraph) rethrows {
        let newGraph = try makeGraph()
        graph.shutdown()
        graph = newGraph
        generation += 1
        onRebuild?()
    }

    /// Flips Hostile Location Protection: wipes everything cached on disk,
    /// then persists the flag and swaps in a graph built for the new mode
    /// (in-memory when enabled). On enable nothing pre-toggle survives; on
    /// disable the in-memory contents are simply dropped and the fresh disk
    /// store starts empty.
    ///
    /// The wipe covers the mail store, contact photos, staged attachments,
    /// delivered notifications, and open compose drafts — everything the
    /// feature's copy promises. It used to cover only the first and third.
    func setHostileLocationProtection(_ enabled: Bool) throws {
        let store = graph.hostileLocationProtectionStore
        let previous = store.enabled
        do {
            // Wipe before persisting the flag. Setting it first meant a crash,
            // force-quit, or power loss in between left the next launch running
            // in memory — reporting the mode as on — while the complete
            // pre-toggle plaintext store sat on disk with nothing to reconcile
            // it. SingletonGraph re-runs this wipe at launch for the same
            // reason.
            try AppDatabase.deleteStoreFiles()
            try ContactPhotoCache.deleteAll()
            InboxViewModel.purgeAttachmentTempFiles()
            // Sender and subject of everything already delivered sit in
            // Notification Center, which is an on-disk artifact like any other.
            UNUserNotificationCenter.current().removeAllDeliveredNotifications()
            // The compose scene value is archived for state restoration, and a
            // reply's body is the full quoted plaintext of the received
            // message. `.id(generation)` recreates the view inside the window,
            // not the window, so the draft would otherwise survive — and the
            // confirmation dialog promises these are closed.
            NotificationCenter.default.post(name: .kyPostCloseComposeWindows, object: nil)

            store.enabled = enabled
            try rebuild { try SingletonGraph() }
        } catch {
            // Leave the app in the mode it was actually built for.
            store.enabled = previous
            throw error
        }
    }

    /// Escape hatch from the app lock, offered by UnlockView after repeated
    /// authentication failures.
    ///
    /// The lock has no bypass by design, which means a device that can no
    /// longer satisfy `LAContext` — biometrics reset, passcode removed,
    /// enrolment changed — otherwise strands the user with their mail behind a
    /// prompt that can never succeed and a settings screen behind the same
    /// lock. This is not a bypass: it reveals nothing, it erases. Everything
    /// cached locally goes, the pairing goes, and the device comes back
    /// unpaired and unlocked, exactly as if it had been reinstalled.
    func resetAfterFailedUnlock() throws {
        // Gated copy and gate flag first: `clear()` routes through the gate,
        // and it must not be the only thing that removes the gated secret.
        graph.credentialGateService.removeAll()
        try? graph.securePairingStore.clear()
        try? graph.desktopSessionStore.clear()
        try? graph.appLockStore.setCredentialGateEnabled(false)
        try graph.appLockStore.setLockEnabled(false)
        try? AppDatabase.deleteStoreFiles()
        try? ContactPhotoCache.deleteAll()
        InboxViewModel.purgeAttachmentTempFiles()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        NotificationCenter.default.post(name: .kyPostCloseComposeWindows, object: nil)
        // The rebuilt graph reads lockEnabled == false, so its AppLockManager
        // comes up unlocked and the cover goes away.
        try rebuild { try SingletonGraph() }
    }
}
