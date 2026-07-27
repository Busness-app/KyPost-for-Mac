# App layer — dependency graph, lifecycle, and the rebuild rule

Scope: `KyPost/App/` — the entry point, delegates, `SingletonGraph`,
`AppEnvironment`, and the pull-polling scheduler.

## The one rule that must not regress

`SingletonGraph.shared` is a **computed alias** into
`AppEnvironment.shared.graph`. Hostile Location Protection swaps the whole
graph at runtime (`AppEnvironment.rebuild`), so:

- **Re-read `SingletonGraph.shared` (or a child) at every use.** Computed
  properties and closure bodies that dereference `.shared` inline are safe.
- **Never capture the graph or one of its children into long-lived state**
  (an `App`-level `@State`, a global, a notification-observer capture list)
  unless that state sits inside a view tree keyed with
  `.id(environment.generation)` — those are torn down and rebuilt on swap.
- Every scene root in `KyPostApp` carries `.id(environment.generation)`.
  A new `WindowGroup`/`Settings` scene must too, plus the `LockedOverlay`
  and `protectedFromCapture()` modifiers its siblings have.
- `SingletonGraph.shutdown()` must stop any new long-lived task a graph
  child owns (pollers, monitors, auto-refresh loops). If you add one,
  add its stop call there, or the superseded graph keeps writing to a
  database the app no longer shows.

`AppEnvironment.onRebuild` re-runs the launch wiring (`PushLifecycle`)
after a swap; it is nil under tests so no runtime services start there.

## Lock ordering at launch

`PushLifecycle.onLaunch` wires `credentialGateService.wireAtLaunch()`
**before** any poll, and `onForeground` is gated on
`appLockManager.isLocked` — the deferred sync runs from `onUnlock`.
Reordering these reintroduces either a blank-secret read (gate on) or a
locked-launch poll.

## Verification

- `xcodebuild test -scheme "KyPost" -destination 'platform=macOS'`
  (`AppEnvironmentTests`, `SecurityTests`).
- The rebuild path is exercised end-to-end by toggling Hostile Location
  Protection in Settings → Security on a paired build.

## Child DOX Index

None.
