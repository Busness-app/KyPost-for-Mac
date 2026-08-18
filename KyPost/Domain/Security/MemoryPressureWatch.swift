//
//  MemoryPressureWatch.swift
//  KyPost
//
//  Drops the unsealed OpenPGP key when the system reports memory pressure.
//
//  Not an optimisation — the key is a handful of bytes and releasing it saves
//  nothing worth measuring. Memory pressure is the moment the kernel starts
//  looking for pages to compress or swap, and a private key that has been
//  written to a swap file has outlived every boundary this app controls.
//  Dropping it costs one authentication prompt.
//

import Foundation

/// Owns a `DispatchSource` memory-pressure monitor for the life of the app.
///
/// Held by the app delegate rather than created and forgotten: a dispatch
/// source is cancelled when its last reference goes, so a fire-and-forget one
/// would stop watching almost immediately.
nonisolated final class MemoryPressureWatch: Sendable {
    private let source: any DispatchSourceMemoryPressure

    /// What pressure means for this app, named so it can be tested.
    ///
    /// The kernel event that fires it cannot be raised from a test, so the
    /// trigger is unverifiable here; the policy it runs is not, and that is
    /// the half that could silently become wrong.
    static let dropSensitiveState: @Sendable () -> Void = {
        EnrollmentSession.shared.clear()
    }

    init(
        queue: DispatchQueue = DispatchQueue(label: "MemoryPressureWatch", qos: .utility),
        onPressure: @escaping @Sendable () -> Void = MemoryPressureWatch.dropSensitiveState
    ) {
        // `.warning` as well as `.critical`: by the time the system reports
        // critical it has already been swapping for a while, which is exactly
        // what this exists to get ahead of.
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: queue
        )
        source.setEventHandler(handler: onPressure)
        source.resume()
        self.source = source
    }

    deinit {
        source.cancel()
    }
}
