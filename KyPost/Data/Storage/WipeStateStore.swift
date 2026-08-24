//
//  WipeStateStore.swift
//  KyPost
//
//  The security wipe's own progress marker. Swift port of the wipe-state half
//  of kypost-android's SecurityWipe.kt.
//
//  **This store must outlive the wipe's own deletions.** `SecurityWipe` sweeps
//  the app's `UserDefaults` domain, and `retainedKeyPrefix` is what keeps this
//  record out of that sweep — an interruption that erased the evidence a wipe
//  was started is exactly the state the marker exists to prevent.
//

import Foundation

nonisolated final class WipeStateStore: Sendable {
    /// Every key here begins with this, and the defaults sweep skips the
    /// prefix rather than a list of names — a list goes stale the first time a
    /// key is added.
    static let retainedKeyPrefix = "wipe."

    private enum Key {
        static let inProgress = "wipe.inProgress"
        static let attempts = "wipe.attempts"
        static let abandoned = "wipe.abandoned"
        static let failedSteps = "wipe.failedSteps"
        static let hostileLocationWasEnabled = "wipe.hostileLocationWasEnabled"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// A wipe started and has not yet finished cleanly.
    var inProgress: Bool { defaults.bool(forKey: Key.inProgress) }

    var attempts: Int { defaults.integer(forKey: Key.attempts) }

    /// The terminal state: the app has stopped resuming the wipe by itself,
    /// **without** forgetting that data may still be here.
    var abandoned: Bool { defaults.bool(forKey: Key.abandoned) }

    var failedSteps: [String] {
        (defaults.array(forKey: Key.failedSteps) as? [String] ?? []).sorted()
    }

    /// The Hostile Location Protection posture captured at the *start* of the
    /// wipe, kept here rather than re-read on a resume.
    ///
    /// Re-reading it would read the defaults an interrupted run already swept,
    /// answer false, and lose the setting permanently — so the user re-pairs
    /// onto a disk-backed plaintext database on a machine the app has just
    /// decided is hostile. Once a wipe has recorded that protection was on,
    /// every resume of that wipe restores it.
    var hostileLocationWasEnabled: Bool { defaults.bool(forKey: Key.hostileLocationWasEnabled) }

    /// Sets the marker, counts this attempt and records the posture, before
    /// anything is destroyed. Returns the posture the *first* run of this wipe
    /// observed.
    ///
    /// The attempt counter belongs to one wipe, not to the install. A set
    /// marker means this run resumes an episode already under way, so the count
    /// climbs and the ceiling bounds it; a clear marker starts a new episode
    /// with the full budget. Ordinary user actions can trigger a wipe, so a
    /// counter monotonic for the life of the install would be spent long
    /// before the wipe that matters — a thief burning PIN attempts — which
    /// would then abandon itself on its first failed step.
    ///
    /// An abandoned episode is over even though its marker is still set, so it
    /// does not lend its spent counter to the next one.
    @discardableResult
    func begin(hostileLocationEnabled: Bool) -> Bool {
        let posture = hostileLocationEnabled || defaults.bool(forKey: Key.hostileLocationWasEnabled)
        let resuming = inProgress && !abandoned
        defaults.set(true, forKey: Key.inProgress)
        defaults.set(posture, forKey: Key.hostileLocationWasEnabled)
        defaults.set(resuming ? attempts + 1 : 1, forKey: Key.attempts)
        defaults.set(false, forKey: Key.abandoned)
        return posture
    }

    /// Persists what this run could not destroy, alongside whether the app has
    /// stopped resuming it.
    func recordFailure(steps: [String], abandoned: Bool) {
        defaults.set(steps, forKey: Key.failedSteps)
        defaults.set(abandoned, forKey: Key.abandoned)
    }

    /// Ends this wipe — **only ever from the clean-run branch**, because these
    /// values are the record that destruction is still owed.
    ///
    /// **The attempt count deliberately stays**, and is reset by `begin` when
    /// it observes a clear marker. Resetting it in both places is what let the
    /// ceiling bound nothing on Android: the counter cycled 1, 2, 0, 1, 2, 0
    /// across seven consecutive failing wipes. Resetting only at episode start
    /// keeps "the ceiling bounds one wipe" true even if this method is edited
    /// later.
    func clear() {
        defaults.removeObject(forKey: Key.inProgress)
        defaults.removeObject(forKey: Key.abandoned)
        defaults.removeObject(forKey: Key.failedSteps)
        defaults.removeObject(forKey: Key.hostileLocationWasEnabled)
    }
}
