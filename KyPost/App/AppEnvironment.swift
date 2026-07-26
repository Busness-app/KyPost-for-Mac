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
}
