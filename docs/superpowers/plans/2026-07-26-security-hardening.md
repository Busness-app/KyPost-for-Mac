# Security Hardening Implementation Plan

Date: 2026-07-26
Implements: `docs/superpowers/specs/2026-07-22-security-hardening-design.md`
(bucket A of the 2026-07-25 Android parity analysis, per
`2026-07-25-android-parity-brief-A-security-hardening.md`).

## Design review — done, decisions ratified

The brief's first move was "review the design against the current tree."
Done 2026-07-26; every load-bearing claim re-verified:

- `HTTPClient.init(session:)` seam and the `Transport` typealias exist
  (`HTTPClient.swift:66-76`). Bonus since the design was written: bucket B
  landed `NetworkError.conflict(body: String)`, so adding a
  `.certificateMismatch` case follows an established pattern.
- `KeychainStorage` stores with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
  (`KeychainStorage.swift:48`), exactly the tradeoff Feature 3 closes.
- `MacPreferencesView` is a six-tab `TabView` (Connection/Appearance/Keywords/
  Contacts/Notifications/Encryption); a seventh Security tab is additive.
- `SettingsViewModel.unpair()` exists (`SettingsViewModel.swift:95`) for the
  pinning recovery path.
- `ScanPgpKeyView.swift:154` still displays the relay-supplied
  `key.fingerprint` — the folded-in bucket-A hole is still open.
- macOS `AppDelegate` has only the `didWakeNotification` observer; no
  screen-lock hook exists. iOS `applicationDidEnterBackground` exists.
- `PullPollingScheduler.pollNow()` already swallows `MailSourceError.notPaired`
  (`PullPollingScheduler.swift:56`) — the pattern Feature 3's
  `credentialUnavailable` joins.
- `SingletonGraph.shared` is referenced **51 times across 14 files** — the
  real size of the graph-rebuild sweep (Task 4 lists them).

Decisions the design recommended, ratified here:

1. **`LAContext.evaluatePolicy(.deviceOwnerAuthentication)` is the only
   unlock mechanism. No custom PIN.** Do not port `PinHasher`/`PinPolicy`/
   `LockoutPolicy`; the OS owns lockout on both platforms.
2. **macOS locks on screen lock, not on focus loss.** The trigger is the
   `com.apple.screenIsLocked`/`com.apple.screenIsUnLocked` distributed
   notifications, a deliberate divergence from iOS's lock-on-background.
3. **Hostile Location Protection rebuilds the dependency graph in place**
   (`AppEnvironment` + `.id(generation)`), not the process. Task 4 is the
   design pass the spec deferred; it lands before and independently of the
   feature that needs it.

## Global constraints

- **No external packages.** OpenPGP fingerprints are hand-rolled over
  CryptoKit (`Insecure.SHA1`); pinning uses `Security.framework` directly.
- TDD with Swift Testing (`@Suite`/`@Test`/`#expect`), tests in
  `KyPost Tests/`, following `TestSupport.swift` (`stubClient`, `Box`,
  `makePairedStore`, scratch `UserDefaults`/`KeychainStorage` suites).
- The target sets `SWIFT_DEFAULT_ACTOR_ISOLATION` to MainActor. Anything
  crossing an isolation boundary (notification observers, URLSession
  delegate callbacks, `@ModelActor` DAOs) needs explicit `nonisolated` /
  `@Sendable` care; pure value types shared across actors must be declared
  `nonisolated` (see `Contact.swift:13-19` for why).
- `LAContext` and access-controlled Keychain items cannot run in unit
  tests. Every feature that touches them goes through an injectable seam
  (protocol or closure, mirroring `HTTPClient.Transport`); the seam gets
  unit tests, the real implementation gets a manual checklist.
- Unit tests run with the app as test host: the app boots
  `SingletonGraph`/`AppEnvironment` at launch. Task 4 must keep that boot
  path working (tests construct their own graphs with in-memory databases,
  as today).
- Any new `@Model` change requires a new versioned schema + stage in
  `AppSchemaVersions.swift` (see its header). No task in this plan touches
  a `@Model`.
- User-facing copy must state platform gaps plainly (Quick Look disk touch,
  iOS screenshot non-prevention) — visible-not-silent, per the design.

## File structure

New files:

```
KyPost/Data/Storage/AppLockStore.swift
KyPost/Data/Storage/HostileLocationProtectionStore.swift
KyPost/Data/Storage/GatedCredentialStore.swift            (Task 6)
KyPost/Data/Networking/PinnedSessionDelegate.swift        (Task 9)
KyPost/Domain/Security/AppLockManager.swift
KyPost/Domain/Security/PgpFingerprint.swift               (Task 10)
KyPost/App/AppEnvironment.swift                           (Task 4)
KyPost/Presentation/Screens/UnlockView.swift
KyPost/Presentation/Screens/SecuritySettingsView.swift    (iOS)
KyPost Tests/SecurityTests.swift
KyPost Tests/PgpFingerprintTests.swift
```

Modified (principal): `KyPostApp.swift`, `AppDelegate.swift`,
`SingletonGraph.swift`, `AppDatabase.swift`, `MacPreferencesView.swift`,
`SettingsView.swift`, `InboxViewModel.swift`, `EmailDetailView.swift`,
`PullPollingScheduler.swift`, `PushNotificationDispatcher.swift`,
`HTTPClient.swift`, `SecurePairingStore.swift`, `ScanPgpKeyView.swift`,
plus the 14-file `SingletonGraph.shared` sweep in Task 4.

## Task order and dependencies

```
T1 stores/manager ─→ T2 lock triggers + UnlockView ─→ T3 settings surface
                                                        │
T4 AppEnvironment graph rebuild (independent spike) ────┼─→ T5 Hostile Location Protection
T1 ────────────────────────────────────────────────────┼─→ T6 unlock-gated credential
                                                        │
T7 capture protection, T8 backup exclusion, T9 TOFU pinning, T10 fingerprint
   (independent of each other; T7/T8 need nothing; T9 needs only T1's test seam pattern)
T11 docs
```

T4 is the risk concentrator. It can start in parallel with T1–T3 and must
merge before T5. If T4 slips, T1–T3 and T6–T10 still ship as a coherent
subset.

---

### Task 1: `AppLockStore`, `AppLockManager`, and the auth seam

**Goal:** all lock state and the unlock decision, with zero UI.

- `AppLockStore` (Keychain-backed via `KeychainStorage`, parallel to
  `SecurePairingStore`): `lockEnabled: Bool`,
  `credentialGateEnabled: Bool` (Feature 3's flag, stored now so the
  store's shape is final). No PIN fields, no lockout fields — ratified
  decision 1.
- `DeviceAuthenticating` seam:
  ```swift
  protocol DeviceAuthenticating: Sendable {
      /// .deviceOwnerAuthentication: biometric first, passcode fallback.
      func canAuthenticate() -> Bool
      func authenticate(reason: String) async -> Bool
  }
  ```
  `LocalAuthenticationAuthenticator` (production, wraps a fresh `LAContext`
  per call — contexts are single-use after invalidation) and a
  closure-driven `StubAuthenticator` in tests.
- `AppLockManager` — `@Observable @MainActor final class`, held in
  `SingletonGraph`:
  - `private(set) var isLocked: Bool` — starts `true` iff
    `store.lockEnabled` at init.
  - `func lock()` — sets `isLocked = true` if `lockEnabled`; also notifies
    Feature 6's credential cache (closure hook, wired in Task 6).
  - `func requestUnlock() async -> Bool` — calls the authenticator; on
    success clears `isLocked`.
  - `func setLockEnabled(_:) async -> Bool` — enabling requires
    `canAuthenticate()` (device has a passcode at all), disabling requires
    a successful `authenticate` first. Returns whether the change took, so
    the settings UI can show the inline explanation instead of a silent
    no-op.

**Tests** (`SecurityTests.swift`): starts-locked-iff-enabled; unlock
success/failure paths; disabling re-authenticates; enabling refused without
device auth capability; `lock()` is a no-op when the feature is off.

---

### Task 2: Lock triggers and `UnlockView`

**Goal:** the lock actually engages and the UI actually gates.

- **iOS trigger:** one line in `PushLifecycle.onBackground()` →
  `graph.appLockManager.lock()`.
- **macOS trigger:** in `AppDelegate.applicationDidFinishLaunching`,
  observe `DistributedNotificationCenter.default()` for
  `"com.apple.screenIsLocked"` → `lock()`. Do **not** observe
  `didResignActiveNotification` (ratified decision 2). Register next to
  the existing `didWakeNotification` observer.
- **Gate the sync side, not just the pixels:** `PushLifecycle.onForeground()`
  skips `startForegroundPolling()`/`pollNow()`/`reconcileNow()` while
  `isLocked`; `AppLockManager` runs them (via a supplied closure) after a
  successful unlock. Locked ≠ unpaired: push *delivery* still works unless
  Feature 3 is on.
- **`UnlockView`:** shared SwiftUI content (app icon, "Unlock KyPost"
  button re-triggering `requestUnlock()`, auto-attempt on appear).
  Presentation is per-platform:
  - iOS: `.fullScreenCover(isPresented:)` bound to `isLocked` on
    `MainTabView`'s root.
  - macOS: a full-window `.overlay` at `rootView` level in `KyPostApp`
    (simplest correct option; an unclosable `NSWindow` is more code for no
    additional guarantee since `sharingType` protection arrives in Task 7).
    The overlay must also cover the pop-out email and compose windows —
    apply the same overlay in those `WindowGroup` roots.

**Tests:** foreground-gating logic (closure-injected scheduler spy);
unlock-runs-deferred-sync. Trigger wiring and overlay behavior are manual:
lock screen (⌃⌘Q) → app locked on return; iOS backgrounding → locked.

---

### Task 3: Security settings surface

**Goal:** the three-toggle screen, with only toggle 1 live; 2 and 3 arrive
disabled ("coming with" their tasks removing the disabled state).

- macOS: new `SecurityPane` tab in `MacPreferencesView` (`Label("Security",
  systemImage: "lock")`), a `Form` with `.formStyle(.grouped)` like its
  siblings.
- iOS: new `Section("Security")` in `SettingsView`'s `Form` linking to
  `SecuritySettingsView`.
- Toggle rules (same order and dependency rules as Android):
  1. **Require Unlock to Open** — flips via
     `AppLockManager.setLockEnabled`; on refusal shows the inline
     explanation ("Set a device passcode to use this").
  2. **Hostile Location Protection** — greyed out unless 1 is on
     (functional in Task 5).
  3. **Require unlock for notifications & MFA** — greyed out unless 1 is
     on; pre-enable confirmation dialog with the delivery-tradeoff copy
     (functional in Task 6).
- Push-metadata disclosure footnote (sender/subject transit the relay) —
  bucket C6's warning lands here for free since the screen is being built.

**Tests:** toggle-dependency logic if extracted into a small view model;
otherwise UI-level rules are covered by `AppLockManager` tests + manual
pass.

---

### Task 4: `AppEnvironment` — the reconstructable dependency graph

**Goal:** the design-level-only mechanism, made concrete. This is the
plan's risk concentrator; it merges alone, with no behavior change for
users (generation never bumps until Task 5 ships).

**Shape:**

```swift
@Observable @MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()
    private(set) var graph: SingletonGraph
    private(set) var generation = 0

    func rebuild(makeGraph: () throws -> SingletonGraph) rethrows {
        graph.shutdown()
        graph = try makeGraph()
        generation += 1
    }
}
```

- `SingletonGraph.shutdown()` (new): stops `pullPollingScheduler`,
  `systemContactsChangeMonitor`, and cancels `InboxViewModel`'s
  auto-refresh task — every long-lived `Task` the graph owns. In-flight
  one-shot tasks (a send, a fetch) are allowed to complete against the old
  graph and drop their results into deallocated view models — harmless,
  but `shutdown()` must ensure nothing *writes to the old database* on a
  timer afterward.
- `SingletonGraph.shared` becomes a thin alias:
  `static var shared: SingletonGraph { AppEnvironment.shared.graph }`.
  **This keeps all 51 call sites compiling unchanged** — the sweep is then
  a correctness review, not a mass edit: each site is fine iff it re-reads
  `.shared` per use (computed properties, function bodies) rather than
  capturing a graph or child object once into long-lived state. Review all
  14 files; the known capture points to fix:
  - `KyPostApp.router` captures `deepLinkHandler` at `@State` init —
    router must survive rebuilds; move `DeepLinkHandler` out of the graph
    or re-wire on rebuild.
  - View-local `private var x: T { SingletonGraph.shared.x }` computed
    properties (MacRootView, MacPreferencesView, SettingsView, etc.) are
    already rebuild-safe — verify, don't touch.
  - `AppDelegate`'s observers and BG-task closures call
    `SingletonGraph.shared` inside the closure body — safe as written.
- `KyPostApp`: `mainWindow` and both auxiliary `WindowGroup`s get
  `.id(environment.generation)` on their root views and
  `.modelContainer(environment.graph.database.container)`. Scene bodies
  re-evaluate when the observable changes; `.id` guarantees teardown of
  every view model holding old DAO references.
- Open auxiliary windows across a rebuild: the pop-out email window
  re-resolves `serverId` against the new graph and shows its existing
  "This email is no longer available." empty state — acceptable, no window
  choreography. Compose windows keep local draft state (`ComposeViewModel`
  is recreated; typed text is lost). **Mitigation:** rebuilds only happen
  from the Security settings toggle; the toggle's confirmation copy warns
  "open compose windows will be closed."

**Verification:** all existing tests pass unchanged (they build their own
graphs); a new `AppEnvironmentTests` suite covers rebuild-bumps-generation,
shutdown-stops-polling (spy scheduler), and shared-alias-tracks-rebuild.
Manual: bump generation from a debug menu item; confirm windows survive,
inbox reloads, no crash with a sheet open.

---

### Task 5: Hostile Location Protection

**Goal:** the user-facing mode, on top of T4. Needs T1–T4.

- `HostileLocationProtectionStore` — `UserDefaults`-backed bool (not
  Keychain; the flag isn't sensitive), read at graph construction:
  `SingletonGraph.init` passes `AppDatabase(inMemory: store.enabled)`.
- `AppDatabase` gains `static var storeURL: URL` (the default
  `ModelConfiguration` location) and
  `static func deleteStoreFiles()` — removes the SQLite file plus `-wal`/
  `-shm` siblings via `FileManager.removeItem`. Plain delete, not secure
  overwrite (explicitly out of scope, flagged).
- Toggle **on** (from the Security pane, behind a confirmation dialog):
  1. re-authenticate (`DeviceAuthenticating`), 2. persist flag,
  3. `AppEnvironment.rebuild { }` where `makeGraph` first calls
  `deleteStoreFiles()`, then builds with `inMemory: true`. Foreground sync
  repopulates from the relay as on first launch.
- Toggle **off**: persist flag, rebuild disk-backed against a fresh file
  (in-memory contents drop; nothing to migrate).
- **Attachments while active** (`InboxViewModel` + `EmailDetailView`):
  - Quick Look keeps writing to the tmp path (platform constraint —
    file-URL-only API), but the file is deleted the moment
    `quickLookURL` returns to nil (`onChange`), and the whole
    `tmp/attachments` tree is purged at mode-enable and at graph
    `shutdown()`.
  - `fileExporter`/Save As is hidden while the mode is active (toolbar
    shows View only) — visible-not-silent.
  - Mode description copy states the tmp-file exposure honestly (the
    design's disclosed gap vs. Android's zero-disk pipe).
- Enable Security-pane toggle 2 (drop its disabled state).

**Tests:** store round-trip; `deleteStoreFiles` removes all three files
(fixture files in a temp dir); graph-built-in-memory-when-flag-set
(construct `SingletonGraph` with a scratch defaults suite and assert no
store file appears); Quick-Look-cleanup logic in `InboxViewModel` (the URL
lifecycle is plain state, testable). Manual: toggle on with mail cached →
list empties then refills from relay; store file gone from
`~/Library/Containers/…/Application Support`.

---

### Task 6: Require unlock to receive push/MFA (credential gate)

**Goal:** Feature 3 — the device secret unreadable without user presence
while locked. Needs T1.

- `GatedCredentialStore`: stores a copy of the device secret as a Keychain
  item with `SecAccessControlCreateWithFlags(…,
  kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, …)`.
  `.userPresence` (not `.biometryCurrentSet`) for parity with
  `.deviceOwnerAuthentication` — Macs without Touch ID still get
  password-gated protection. No AES wrapping layer needed: Keychain's own
  access control does the job the design's Android-derived sketch used
  AES-GCM for; one item, zero custom crypto (consistent with ratified
  decision 1).
- When toggle 3 flips **on**: write the gated copy, delete the plain
  `deviceSecret` from `SecurePairingStore`'s item (the rest of the pairing
  stays). Flipping **off** reverses it (one `.userPresence` prompt to read).
- `SecurePairingStore.loadPairing()` grows a mode-aware read path:
  - gate off → today's behavior, untouched.
  - gate on + unlocked → serve from `AppLockManager`'s in-memory copy
    (populated once per unlock via the access-controlled read — the one
    point the OS may re-prompt).
  - gate on + locked → throw new `MailSourceError.credentialUnavailable`.
- `PullPollingScheduler.pollNow()` and `PushNotificationDispatcher`'s MFA
  path treat `credentialUnavailable` exactly like `notPaired`: log, no
  toast, retry on next unlock (which already triggers a poll via Task 2's
  deferred-sync hook).
- `AppLockManager.lock()` drops the in-memory copy (the closure hook left
  in Task 1).
- Enable Security-pane toggle 3; confirmation copy includes the
  macOS-vs-iOS behavioral difference (macOS: only the locked-screen
  window; iOS: also the whole background-refresh window).

**Tests:** mode-aware `loadPairing` matrix (gated store stubbed behind a
protocol — real access control can't run headless); poller/MFA
`credentialUnavailable` no-op paths; lock-drops-cache. Manual: enable,
lock screen, send yourself mail → no notification; unlock → poll delivers
it.

---

### Task 7: Screen-capture protection

Independent; no dependencies.

- **macOS:** `WindowSharingDisabler` — an `NSViewRepresentable` that walks
  to its `window` on `viewDidMoveToWindow` and sets `sharingType = .none`.
  Applied via a `.protectedFromCapture()` view-extension to: main window
  root, email pop-out root, compose root, Security pane, `UnlockView`.
  Blocks recordings/sharing; does **not** block ⌘⇧3 screenshots — say so
  in the Security pane footer.
- **iOS:** observe `UIScreen.capturedDidChangeNotification`; while
  `isCaptured`, blur inbox/detail/compose/security/unlock via a shared
  modifier (`.redacted(reason:)` + blur overlay). No screenshot
  *prevention* attempt — the secure-text-field overlay hack is explicitly
  rejected (fragile, undocumented, Apple is tightening against it).

**Tests:** the modifier's state logic only. Behavior verified manually
(start a QuickTime screen recording; confirm window is black on macOS,
blurred content on iOS).

---

### Task 8: Backup exclusion

Independent; tiny.

- At launch (once, in `SingletonGraph.init` after `AppDatabase` is up) and
  after every Task-5 rebuild: set
  `URLResourceValues.isExcludedFromBackup = true` on `AppDatabase.storeURL`
  (and siblings) and on the `tmp/attachments` directory. Log-and-continue
  on failure; never fatal.
- Keychain items already `ThisDeviceOnly` — no change, assert nothing.

**Tests:** resource value round-trips on a fixture file in a temp
directory.

---

### Task 9: TOFU certificate pinning

Independent of T1–T8; touches networking only.

- `PinnedSessionDelegate: NSObject, URLSessionDelegate` implementing
  `urlSession(_:didReceive:completionHandler:)`:
  - No stored pin yet (pre-pairing / first contact): perform default
    handling, but compute and expose the leaf SPKI SHA-256 so the pairing
    flow can capture it.
  - Stored pin: compare; match → `.performDefaultHandling`;
    mismatch → `.cancelAuthenticationChallenge`.
  - SPKI extraction via `SecCertificateCopyKey` +
    `SecKeyCopyExternalRepresentation`, hashed with CryptoKit `SHA256`,
    prepending the algorithm header for the key type (RSA/EC) so the pin
    matches `openssl`-computed SPKI hashes.
- `SecurePairingStore` gains `pinnedSpkiHash: String?` (new Keychain field
  beside `srv`; follow `Config.swift`'s binding-contract comment
  convention).
- `SingletonGraph` builds one pinned `URLSession` and passes it to
  `HTTPClient.init(session:)` in place of `.shared`.
- Capture point: when `DeviceRegistrationService.pair` succeeds, persist
  the hash the delegate saw on that handshake.
- `NetworkError.certificateMismatch` (new case, distinct from
  `.transport`); the delegate's cancellation is mapped to it in
  `HTTPClient`. Surfaced as its own UI state on Connection settings with a
  "Clear pairing and re-pair" action reusing `SettingsViewModel.unpair()`.
- Stated limitation carried into the code comment: protects post-pairing
  only; initial pairing trusts the scanned `srv` URL.

**Tests:** delegate decision matrix with certificates loaded from DER
fixtures (match/mismatch/no-pin); SPKI-hash known-answer test against a
fixture cert whose hash was computed with `openssl` offline;
`certificateMismatch` mapping in `HTTPClient`. The full TLS handshake path
is manual (pair against the real relay, then flip the stored pin and
confirm the hard-fail + recovery UI).

---

### Task 10: Locally computed PGP fingerprints

Independent; closes the relay-trust hole folded in from bucket B.

- `PgpFingerprint.swift` (~150 lines): de-armor (strip header/footer/CRC,
  base64-decode), parse the OpenPGP packet stream far enough to find the
  first public-key packet (tag 6, old and new packet-length formats), then
  v4 fingerprint = SHA-1 over `0x99 || 2-byte length || packet body`
  (CryptoKit `Insecure.SHA1` — mandated by RFC 4880, not a crypto choice
  we own). Return nil on anything malformed; never trust-and-fall-back.
- `ScanPgpKeyView` displays the *computed* fingerprint of the received
  armored key. If it differs from the relay-supplied `fingerprint` field,
  show the mismatch as a warning and refuse the save — that discrepancy is
  precisely the attack the feature exists to catch.
- Coordinate note (from brief C4): the computed fingerprint is the one
  stored/displayed everywhere from now on; if bucket C's identity badges
  land later they must consume this, not the DTO field.

**Tests** (`PgpFingerprintTests.swift`): known-answer vectors — at least
one RSA and one EC key generated offline with GnuPG, armored fixture +
expected fingerprint string; malformed-armor/truncated-packet/garbage
inputs return nil; mismatch-refuses-save at the view-model level.

---

### Task 11: Documentation

- README: Security section — the three settings, what each does and does
  not protect against, per platform (screenshots on macOS, background
  windows on iOS, tmp-file exposure during Quick Look).
- `KyPost/Presentation/AGENTS.md` (or nearest): note `AppEnvironment` /
  `SingletonGraph.shared`-alias rule — never capture graph children into
  long-lived state; always re-read.
- Mark the 2026-07-22 spec Status: implemented-by this plan; note the two
  deltas (no AES wrapping layer in Feature 3; macOS overlay instead of a
  dedicated unlock NSWindow).

## Explicitly not in this plan

Everything the spec's own out-of-scope list names: custom PIN and its
machinery, duress codes, jailbreak detection, clipboard flagging, secure
store overwrite, unconditional Quick-Look tmp cleanup outside the mode
(worth a separate small change), iOS screenshot blocking, and server-side
token scoping. Also bucket C in its entirety (no design exists yet).

## Verification gate

Per task: `xcodebuild test -scheme "KyPost" -destination 'platform=macOS'`
plus that task's manual checklist. Whole-plan exit: all three toggles
exercised on macOS hardware with and without Touch ID, and on an iOS
device (Simulator cannot exercise `LAContext` biometrics or real APNs);
a full unpair→re-pair cycle against the relay with pinning active.
