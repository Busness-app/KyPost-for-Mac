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
    static let shared = AppEnvironment(graph: {
        do {
            return try SingletonGraph()
        } catch {
            fatalError("Could not build dependency graph: \(error)")
        }
    }())

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
}
