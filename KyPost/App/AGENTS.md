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
- `SingletonGraph.shutdown()` must stop any new long-lived task or resource
  a graph child owns (pollers, monitors, auto-refresh loops, and
  `relaySession`, whose delegate-backed `URLSession` holds its delegate and
  connection pool until `invalidateAndCancel()`). If you add one, add its
  stop call there, or the superseded graph keeps writing to a database the
  app no longer shows — or, worse, keeps relay connections open through the
  Hostile Location Protection swap that was meant to close them.

`AppEnvironment.onRebuild` re-runs the launch wiring (`PushLifecycle`)
after a swap; it is nil under tests so no runtime services start there.

## Lock ordering at launch

`PushLifecycle.onLaunch` wires `credentialGateService.wireAtLaunch()`
**before** any poll, and `onForeground` is gated on
`appLockManager.isLocked` — the deferred sync runs from `onUnlock`.
Reordering these reintroduces either a blank-secret read (gate on) or a
locked-launch poll.

`wireAtLaunch` is also the credential gate's only repair point: the gate
enabled *without* the app lock is a state the running session cannot escape
(its toggle is disabled, and `requestUnlock` returns early once unlocked, so
the in-memory secret can never come back). Settings refuses to create it —
`SecuritySettingsView` clears the gate *before* dropping the lock and aborts
the whole change if that fails — and a relaunch resolves it if a partial
write ever does.

## Verification

- `xcodebuild test -scheme "KyPost" -destination 'platform=macOS'`
  (`AppEnvironmentTests`, `SecurityTests`).
- The rebuild path is exercised end-to-end by toggling Hostile Location
  Protection in Settings → Security on a paired build.

## Child DOX Index

None.
