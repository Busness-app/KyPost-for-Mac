# Security hardening: app lock, Hostile Location Protection, and related mitigations

Date: 2026-07-22
Status: Draft — ported from kypost-android's 2026-07-22-security-hardening-design.md, not yet reviewed

## Goal

Add two user-facing security settings plus a set of supporting hardening
measures, for both the macOS and iOS targets of this single codebase:

1. **Require Unlock to Open** — gate the app's UI behind the device
   passcode/biometric (or, if we decide against that, an app-specific PIN).
2. **Hostile Location Protection** — a mode with no on-device cache of mail,
   contacts, keywords, or attachments, for use in high-risk situations
   (border crossings, device-seizure risk).
3. **Require unlock to receive push/MFA** — an opt-in, off-by-default
   extension of #1 that also gates the relay device credential itself, at
   the cost of background push/pull/MFA while locked.

Plus: screenshot/screen-recording mitigations on sensitive screens (subject
to real platform limits — see below), excluding local data from
backups, and TOFU certificate pinning for the relay connection.

Like kypost-android, this app has no on-device PGP private key: decryption
happens server-side on kypost-server, and the relay API returns mail
bodies already decrypted (see `KyPost/Data/Mail/RelayMailSource.swift`,
`KyPost/Domain/Repositories/`). The Mac/iOS client only ever handles PGP
**public** keys, exchanged via QR (`KyPost/Data/Networking/PgpQrClient.swift`,
`KyPost/Presentation/Screens/MyPgpQrCodeView.swift`). Same simplification as
Android: Hostile Location Protection here means "don't cache already-decrypted
content," not "don't lose key material."

## Current architecture (relevant pieces) — kypost-for-Mac

Verified by reading the actual files; corrections to the Android session's
guesses and to the prior audit summary are called out inline.

- **Persistence**: `KyPost/Data/Database/AppDatabase.swift` owns one
  SwiftData `ModelContainer`, built from a `ModelConfiguration` that already
  accepts `isStoredInMemoryOnly: Bool` (used today for tests, not for a
  user-facing mode):

  ```swift
  init(inMemory: Bool = false) throws {
      let configuration = ModelConfiguration(schema: Self.schema, isStoredInMemoryOnly: inMemory)
      container = try ModelContainer(for: Self.schema, migrationPlan: AppMigrationPlan.self, configurations: [configuration])
  }
  ```

  So SwiftData's in-memory mode is real and already plumbed — feature 2's
  core mechanism is a straight reuse, not new work. What is *not* free: the
  container is owned by `SingletonGraph.shared`, a `static let` constructed
  once (`KyPost/App/SingletonGraph.swift`), and every DAO/repository
  (`emailDAO`, `contactDAO`, `pushNotificationDAO`, `mailRepository`, …) is a
  `lazy var` that captures `database.container` directly at first access —
  not looked up freshly from environment on each use. `KyPost/App/KyPostApp.swift`
  also binds the container once, at the top-level `WindowGroup`:
  `.modelContainer(graph.database.container)`. See "Toggling on/off" below
  for what this means for the relaunch question the Android doc flagged.

- **Credential storage**: `KyPost/Data/Storage/KeychainStorage.swift` wraps
  `SecItemAdd`/`SecItemCopyMatching` and stores every item with
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — **not**
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, which the Android
  session's porting note guessed. This is a deliberate, already-documented
  tradeoff (see the file's own header comment): background pull-polling
  (`PullPollingScheduler`) must read the credential without the user
  present, which `WhenUnlocked` would forbid. The comment already flags the
  natural next step — "splitting biometry-gated items into a separate
  access group" — which is exactly feature 3 below.
  `KyPost/Data/Storage/SecurePairingStore.swift` sits on top of this and
  holds `sub`, `deviceSecret`, `srv`, `registrationUrl`, `pairingToken`,
  `lastDeviceId`, `pairedAtTimestamp` — the Mac/iOS equivalent of Android's
  `SecurePairingStore`. Practical effect: once the device has been unlocked
  once since boot, the pairing credential is decryptable by the running
  process at any time thereafter, screen-locked or not — the same "at rest
  encrypted, but not gated behind user presence" property Android's doc
  describes for `EncryptedSharedPreferences`. Feature 3 closes the same gap
  here that it closes there.

- **App lifecycle**: there is no `ScenePhase` observation today. Real hooks
  live in `KyPost/App/AppDelegate.swift`, which is genuinely different per
  platform and shared through a `PushLifecycle` enum:
  - iOS: `UIApplicationDelegate.applicationDidBecomeActive` /
    `applicationDidEnterBackground`, plus a registered `BGAppRefreshTask`
    (`Config.backgroundPullTaskId`) that fires roughly every 15 minutes
    while backgrounded to run one pull poll.
  - macOS: `NSApplicationDelegate.applicationDidFinishLaunching` calls
    `PushLifecycle.onForeground()` once at launch and never again — **macOS
    has no background/foreground app-lifecycle transition at all in this
    app**. Foreground polling (`PullPollingScheduler`, every 90s per
    `Config.foregroundRefreshInterval`) simply keeps running the entire
    time the app process is alive, comment: "macOS has no background app
    refresh; resume polling on wake and let the app poll full-time while
    running." The only lifecycle hook present is
    `NSWorkspace.didWakeNotification`, used to force one poll after the Mac
    wakes from sleep — nothing observes window resign-key, screen lock, or
    app deactivation today. **This is a real gap for "lock immediately on
    backgrounding": macOS needs a hook that doesn't exist yet.** The
    natural ones to add: `NSApplication.didResignActiveNotification` (app
    loses focus — closest analog to Android backgrounding, but a user
    routinely alt-tabs away without wanting to be locked) and/or
    `com.apple.screenIsLocked`/`com.apple.screenIsUnLocked` distributed
    notifications (screen saver / login window engaged — a much closer
    match to "device left unattended" and the one this design recommends,
    see Feature 1 below). Neither is wired up anywhere in the codebase
    today.
  - iOS has the closer analog: `applicationDidEnterBackground` fires
    whenever the app stops being the foreground app for any reason
    (home button, app switch, screen lock, incoming call) — a direct,
    already-present hook to lock on.

- **Push/pull/MFA background delivery**: confirms the same "must
  authenticate unattended" tension Android's feature 3 describes.
  `PullPollingScheduler.pollNow()` and the `BGAppRefreshTask` handler in
  `AppDelegate` call `pushRepository.pullOnce()`, which reads
  `securePairingStore` and sends `RelayAuth` headers — no user presence
  involved, by design, on both platforms. `MfaResponseClient.swift`
  (`POST {srv}/api/mfa/push/respond`) authenticates the exact same way,
  confirmed by its own header comment: "the device authenticates via
  X-Kypost-Device-Id/X-Kypost-Device-Secret headers (RelayAuth), same as
  every other authenticated Relay endpoint." `PushNotificationDispatcher`
  is where an incoming push (`didReceiveRemoteNotification`) or a local
  pull result gets turned into a delivered notification and, for MFA
  challenges, an approve/deny action — all of this runs whether or not a
  human is present, exactly the surface feature 3 needs to gate.

- **Attachments**: does *not* always write to disk today, contrary to what
  Android's doc assumes about "typical" mobile attachment handling.
  `InboxViewModel.swift` (`attachmentData`, `downloadAttachment`,
  `sanitizedCacheComponent`) and `EmailDetailView.swift` show two paths:
  - **Quick Look** (view in place): `downloadAttachment(_:of:)` downloads
    bytes, then writes them to
    `FileManager.default.temporaryDirectory/attachments/<serverId>/<index>/<safeName>`
    and hands the resulting file `URL` to SwiftUI's
    `.quickLookPreview($quickLookURL)`. This *does* touch disk (the app's
    own tmp directory, not Downloads/Photos — meaningfully more contained
    than Android's default "public storage," but still a real file on
    disk).
  - **Save As** (`fileExporter`): downloads bytes into an in-memory
    `AttachmentDocument`/`FileDocument` and only writes to disk at the
    location the user picks in the system save panel — the bytes never
    touch app-controlled disk storage before that point.
  - `sanitizedCacheComponent` already guards `email.serverId` against `/`,
    `..`, and NUL before it's used as a path component — a narrower,
    already-applied version of the path-traversal mitigation the prior
    audit flagged as missing elsewhere in the codebase (e.g. relay-facing
    URL construction). Worth a one-line cross-reference only: Hostile
    Location Protection's attachment redesign below inherits this same
    sanitization, it doesn't need to reinvent it.
  - **QuickLook API constraint (important correction to the Android
    porting note):** SwiftUI's `.quickLookPreview(_:)` modifier takes a
    `Binding<URL?>` — there is no supported in-memory/`Data`-backed
    variant. Unlike Android's `ContentProvider`-backed pipe, which can
    serve bytes to the "open with" flow without ever writing them to disk,
    **QuickLook on both macOS and iOS fundamentally requires a file URL.**
    A genuinely disk-free attachment-view path, as Android's design
    describes, is not achievable here with the platform's built-in
    preview API. See Feature 2 below for the resulting design call.

- **Settings UI**: two real, already-diverging screens exist, matching
  Apple's own platform conventions —
  `KyPost/Presentation/Screens/SettingsView.swift` (iOS: a `Form` reached
  via in-navigation push, grouped `Section`s, `NavigationLink` for
  sub-screens like `KeywordSettingsView`) and
  `KyPost/Presentation/macOS/MacPreferencesView.swift` (macOS: a native
  `Settings { }` scene opened via ⌘, rendered as a `TabView` of six
  toolbar-style panes — Connection/Appearance/Keywords/Contacts/
  Notifications/Encryption — each its own `Form` with `.formStyle(.grouped)`).
  Both bind to the same shared `SettingsViewModel`. New settings need a
  home in both: a new toggle in iOS's `SettingsView` `Form`, and a new
  `MacPreferencesView` tab (`Security`, alongside Connection/Notifications)
  on macOS — not shoehorned into an existing pane, matching how
  Notifications already gets its own tab there.

- **Networking**: `KyPost/Data/Networking/HTTPClient.swift` wraps a
  `Transport` closure, and its default initializer uses `URLSession.shared`
  directly — **no custom `URLSessionDelegate` exists anywhere today**
  (correction to the Android porting note, which assumed a delegate hook
  was already there to extend). `URLSession.shared` cannot take a delegate.
  TOFU pinning therefore needs a new, dedicated `URLSession` — built with
  `URLSessionConfiguration.default` and a custom delegate class
  implementing `urlSession(_:didReceive:completionHandler:)` — constructed
  once in `SingletonGraph` and passed into `HTTPClient.init(session:)` in
  place of `.shared`. Mechanically small (the injection seam already
  exists via `HTTPClient.init(session:)` and the `Transport` typealias),
  but it is new plumbing, not a hook that's already wired up.

- **Entitlements/sandbox**: two separate files,
  `KyPost/KyPost.entitlements` (macOS) and `KyPost/KyPost_iOS.entitlements`
  (iOS). Both request `aps-environment` (push) and a shared
  `keychain-access-groups` entry
  (`$(AppIdentifierPrefix)com.urlxl.llama-Mail-for-Mac`). macOS additionally
  has `com.apple.security.network.client`,
  `com.apple.security.files.user-selected.read-write`, and
  `com.apple.security.personal-information.addressbook` — i.e. **App
  Sandbox is on for macOS** (Automation/Family-of-entitlements form implies
  it; consistent with the prior audit's "App Sandbox + Hardened Runtime
  both ON"). Nothing in either file today excludes app data from backup, and
  nothing restricts screen capture. Neither sandbox profile blocks any API
  this design needs: `LocalAuthentication`, additional Keychain items, a
  second `URLSessionDelegate`, `NSWindow.sharingType`, or
  `isExcludedFromBackupKey` all work fine under App Sandbox with the
  entitlements already present — no entitlement changes required for this
  feature set, only new code.

- **Biometrics**: `LocalAuthentication`/`LAContext` is not used anywhere in
  the codebase today — confirmed absent (no import, no reference). This
  design introduces it fresh. Platform asymmetry to design around: iOS has
  near-universal Face ID/Touch ID; macOS has Touch ID only on machines with
  the hardware (recent MacBook Pro/Air, Magic Keyboard with Touch ID) and
  **no biometric at all on many desktop Macs** (Mac mini, Mac Studio, many
  external-display iMac setups without a Touch ID keyboard). `LAContext`
  already reports this correctly via `canEvaluatePolicy(_:error:)`
  (`.biometryNotAvailable`), so the UI degradation ("PIN/passcode only, no
  biometric row shown") is a query against the live context, not a
  platform `#if` — same code path handles both targets and both
  hardware configurations naturally.

## New module: `KyPost/Security/`

Mirrors Android's `com.urlxl.mail.security` package, adapted to this
codebase's existing `Data/Storage` + `Domain` + `Presentation` layering:

- `Data/Storage/AppLockStore.swift` — Keychain-backed settings (parallels
  `SecurePairingStore`, same `KeychainStorage` dependency):
  - `lockEnabled: Bool`
  - `biometricEnabled: Bool`
  - `failedAttemptCount: Int`
  - `lockoutUntilTimestamp: Date?`
  - `credentialPinGateEnabled: Bool` (feature 3)
  - If we ship a custom PIN (see Feature 1 decision below): PIN stored the
    same way Android does — `(salt, PBKDF2(pin, salt, 150_000 rounds,
    SHA256, 256-bit))`, never the raw PIN, as a Keychain item with
    `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (stricter than the
    pairing credential's own access class is fine here — the PIN
    verifier is only ever needed while the user is actively unlocking,
    never from a background task).
- `Domain/Security/AppLockManager.swift` — `@Observable` (this codebase's
  established pattern for shared mutable UI state, e.g. `ThemeManager`,
  `NavigationRouter`), not persisted: `var isLocked: Bool`. "Locked" means
  "since this process started, has the correct unlock been presented" —
  identical semantics to Android's in-memory `MutableStateFlow`. Held in
  `SingletonGraph` alongside the other shared managers.
- `Presentation/Screens/UnlockView.swift` — full-screen SwiftUI cover
  (`.fullScreenCover` on iOS; a borderless, unclosable `NSWindow` or a
  root-view overlay on macOS — macOS has no `fullScreenCover` scene-cover
  equivalent, so this needs its own per-platform presentation even though
  the unlock UI itself is shared).
- `Presentation/Screens/SecuritySettingsView.swift` (iOS `Form` section) and
  a new `SecurityPane` in `MacPreferencesView.swift` (macOS tab) — same
  three toggles as Android, described below.

## Feature 1 in detail: Require Unlock to Open

### Design decision: lean on the platform passcode, don't roll a custom PIN

The Android porting note flagged this as an open question; here is the
call, with reasoning, since a Mac/iOS design should not default to
Android's answer just for parity:

**Recommendation: use `LAContext.evaluatePolicy(.deviceOwnerAuthentication,
...)` as the primary and only unlock mechanism — no custom PIN screen.**

Reasoning:
- `.deviceOwnerAuthentication` already does exactly what Android's design
  hand-builds: biometric first (Face ID/Touch ID where enrolled), falling
  back to the device passcode, with the OS's own rate-limiting and wipe
  policy (iOS: passcode lockout escalates automatically and is enforced by
  the Secure Enclave, not app code; macOS: the login/screen-lock password
  policy applies). A custom PIN would duplicate all of Android's lockout
  bookkeeping (`failedAttemptCount`, escalating delays,
  `lockoutUntilTimestamp`, the 10-attempt wipe) in application code, for a
  security property the OS already provides for free and enforces more
  robustly (hardware-backed on iOS).
  - The app-level state this design still needs — `AppLockStore.lockEnabled`,
    `AppLockManager.isLocked` — stays exactly the same shape either way;
    only the *verification* step changes from "check PIN hash" to "call
    `LAContext`."
- It sidesteps an awkward asymmetry a custom PIN would create on macOS:
  many Macs have no biometric hardware, so "PIN with optional biometric
  convenience unlock" (Android's framing) would degrade to "our own PIN
  screen with no convenience option" on a large share of Mac hardware —
  worse than just asking for the Mac's own login password, which every Mac
  already has.
- The cost: unlocking this app becomes "prove you are this Mac/iPhone's
  owner," not "prove you know this app's specific PIN." That is a
  materially different (and, per the Android doc's own porting note,
  arguably stronger) security boundary — worth stating explicitly as the
  tradeoff being made, not glossed over. A user who shares their device
  passcode with someone (a partner, a family member) but wanted an
  app-specific secret loses that separation. If that scenario turns out to
  matter to real users, a custom-PIN fallback (`.deviceOwnerAuthentication`
  first, with an app PIN as a second, app-specific factor) is the
  incremental next step — not in scope for this draft.
- `LAContext` also directly answers feature 3's need for a
  biometry-gated Keychain access-control flag: `kSecAccessControlBiometryCurrentSet`
  (or, for `.deviceOwnerAuthentication` parity, `.userPresence`) ties a
  Keychain item to "the currently enrolled biometry/passcode," with no
  separate PIN-derived key needed on the storage side — see Feature 3.

### AppLockManager behavior
- On process init: if `lockEnabled`, start `isLocked = true`.
- On backgrounding (see per-platform hooks below): if `lockEnabled`, set
  `isLocked = true` immediately — no grace period, matching Android.
- On foregrounding: if `isLocked`, present `UnlockView` before any sync
  call runs (i.e. before `PushLifecycle.onForeground()`'s
  `pullPollingScheduler.startForegroundPolling()` / `pollNow()` calls —
  those need to be gated behind the unlock check, not just delayed
  visually).
- Successful `LAContext` evaluation clears `isLocked`.

### Per-platform lock trigger — this is where the two targets genuinely diverge
- **iOS**: `AppDelegate.applicationDidEnterBackground` already exists and
  already fires on every path that should trigger a lock (home button,
  app switcher, screen lock, incoming call taking over the screen). Add
  the `AppLockManager` set-locked call into `PushLifecycle.onBackground()`
  directly — this is a one-line addition to an existing, correct hook.
- **macOS**: no equivalent hook exists today (see "Current architecture"
  above). Recommend `NSWorkspace.shared.notificationCenter` observers for
  `screenIsLockedNotification`/`screenIsUnLockedNotification`
  (screen saver or login window engaging — the actual "device left
  unattended" signal) as the primary trigger, registered next to the
  existing `didWakeNotification` observer in
  `AppDelegate.applicationDidFinishLaunching`. Do **not** lock on plain
  `NSApplication.didResignActiveNotification` (losing focus to another
  app) — unlike an iOS app being backgrounded, a Mac user switching
  windows or apps constantly is normal, expected behavior, and locking on
  every focus loss would make the feature unusable (unlock prompt every
  few seconds). This is a deliberate, named divergence from Android/iOS's
  "lock immediately on backgrounding" policy: on macOS, "backgrounding"
  and "left unattended" are not the same event, and the policy should
  track the latter.

### Lockout policy
Not owned by this app at all, on either platform — inherited entirely from
`LAContext`/the OS passcode policy (see the design decision above). No
`failedAttemptCount`/escalating-delay/wipe-at-10 logic to build or
maintain in `AppLockStore`.

### Settings screen — three toggles, same order and dependency rules as Android
1. **Require Unlock to Open** (`AppLockStore.lockEnabled`). Turning on
   calls `LAContext.canEvaluatePolicy(.deviceOwnerAuthentication)` once to
   confirm the device has *something* configured (passcode/login password
   at minimum) before flipping the toggle — if the device has no passcode
   at all, show an inline explanation instead of a silent no-op (mirrors
   Android's toggle-2/3 dependency messaging). No PIN-entry UI, per the
   decision above. Turning off re-authenticates first via `LAContext`,
   then clears lock state.
2. **Hostile Location Protection** — disabled/greyed out unless toggle 1
   is on, same as Android, same inline-explanation-not-silent-no-op rule.
3. **Require unlock to receive push/MFA** — off by default, disabled
   unless toggle 1 is on, same pre-enable modal copy as Android's design
   (adapted: "...new-mail notifications and MFA approval requests will
   only be delivered after you open the app and unlock it...").

## Feature 2 in detail: Hostile Location Protection

### Data layer: in-memory SwiftData is already half-built
`AppDatabase.init(inMemory:)` already supports this exact mode — the flag
just needs to be read from `AppLockStore`-adjacent settings (a new
non-secret `HostileLocationProtectionStore`, plain `UserDefaults`-backed
like `KeywordSettingsStore`/`PushSettingsStore` — not Keychain, matching
Android's reasoning that the flag itself isn't sensitive) instead of being
test-only.

### The relaunch question — answered from the real dependency graph, not assumed
The Android doc explicitly asks whether this platform can hot-swap the DB
live or needs Android's process-restart pattern. Verified answer: **partial
hot-swap is technically possible, but the current DI graph is not built for
it, and the Android answer — "force a full restart" — does not have a
clean iOS equivalent to fall back on.**

- SwiftData itself has no objection to rebuilding a `ModelContainer` in
  place — construct a new `AppDatabase(inMemory: true)` and you have a
  valid, working container immediately, no process involved.
- The obstacle is entirely in this app's own wiring: `SingletonGraph.shared`
  is a `static let`, and every DAO/repository/view-model that touches
  persistence captures `database.container` (or a DAO built from it) once,
  at first `lazy var` access, via constructor injection — not via
  `@Environment(\.modelContext)` lookups that would pick up a swapped
  container automatically. `KyPostApp.swift`'s `.modelContainer(graph.database.container)`
  is likewise set once per `WindowGroup`. Swapping `AppDatabase` alone
  would leave every already-constructed `EmailDAO`/`ContactDAO`/
  `MailRepository`/`InboxViewModel` (itself cached in `SingletonGraph` and
  handed to views) pointing at the old container — exactly the
  "already-created ViewModels/Activities holding references to the old
  one" problem Android's doc describes for Room, not a SwiftData-specific
  limitation.
- Unlike Android, this app cannot fall back on "kill and relaunch the
  process": iOS has no supported API for an app to terminate and relaunch
  itself (calling `exit()` just quits — the user has to reopen it
  manually, which is a materially worse UX than Android's transparent
  auto-relaunch and not an acceptable substitute for "toggle a setting").
  macOS *can* relaunch itself (spawn a fresh copy of the running app
  bundle via `NSWorkspace`/`Process`, then call
  `NSApplication.terminate(_:)`), but building two completely different
  toggle-flows per platform for the same setting is exactly the kind of
  divergence this design should avoid when it isn't forced.

**Recommendation: rebuild the dependency graph in place, not the process.**
Make `SingletonGraph` reconstructable — replace the `static let shared`
singleton with a small `@Observable` holder (e.g. `AppEnvironment`) whose
`graph: SingletonGraph` property can be reassigned, and key the root view
(`rootView` in `KyPostApp.swift`) with `.id(environment.generation)` so
SwiftUI tears down and rebuilds the entire view subtree — including every
view model that was holding stale DAO/repository references — whenever the
graph is swapped. Concretely, toggling Hostile Location Protection on:

1. Persist the flag = true (`HostileLocationProtectionStore`).
2. Construct a fresh `SingletonGraph` with `AppDatabase(inMemory: true)` —
   after first deleting the on-disk store file(s) (SwiftData's SQLite file
   + `-wal`/`-shm` siblings, at the `ModelConfiguration`'s default URL) so
   nothing pre-toggle survives, matching Android's "wipe immediately on
   enable" rule.
3. Assign the new graph into `AppEnvironment`, bump `generation`.
4. SwiftUI rebuilds the view tree from the new `.modelContainer` and fresh
   view models; the existing foreground sync (`PushLifecycle.onForeground()`
   equivalent) repopulates the in-memory store exactly as on first launch.

Toggling off mirrors this: persist flag = false, rebuild
`SingletonGraph`/`AppDatabase` disk-backed against a fresh empty file
(in-memory data is simply dropped, nothing to migrate — same as Android),
bump generation.

This achieves the same net effect as Android's process restart — a clean
break so no stale reference outlives the swap — without relying on an
OS-level relaunch this platform doesn't reliably support. It is more
invasive to build than Android's version (Android gets the "throw away
everything and start over" reset for free from the OS; here it has to be
built explicitly as a graph-rebuild), which is worth flagging as the real
implementation cost of this feature on this platform. **This app-level
rebuild is a genuine new mechanism, not present anywhere in the codebase
today** (`SingletonGraph.shared` is currently assumed immutable
everywhere) — it is the single largest architectural change this design
introduces, and should get its own design review/spike before being
folded into an implementation plan.

### Attachments
Given the QuickLook constraint confirmed above (file-URL-only, no
in-memory preview path on either platform), Android's "disk-free pipe"
approach cannot be ported as-is. Recommended design for Hostile Location
Protection mode:

- Continue writing the Quick-Look temp file to
  `FileManager.default.temporaryDirectory/attachments/...` (same path
  `InboxViewModel.downloadAttachment` already uses) — this directory is
  already the most disk-minimal option the platform's own preview API
  allows, and iOS/macOS both purge it opportunistically under storage
  pressure and (on iOS) between launches, unlike Downloads.
  - what changes: delete the file immediately once QuickLook is
    dismissed (currently nothing cleans this directory up at all — a
    pre-existing gap, worth closing regardless of Hostile Location
    Protection, but mandatory once this mode exists), and skip
    `.fileExporter`/Save As entirely while the mode is active — the toolbar
    action changes from "Save As…" to "View" only, same visible-not-silent
    principle as Android's label change.
  - This is a real, disclosed platform gap versus Android's design, not a
    hidden shortcut: while Hostile Location Protection is on, an
    attachment's decrypted bytes do briefly touch disk (the sandboxed tmp
    directory) for the duration of the Quick Look session, then are
    deleted. It is a materially smaller exposure than the app's own normal
    Save-As/Downloads behavior, but it is not the zero-disk-touch
    guarantee Android's Content-Provider pipe achieves. State this
    explicitly in the in-app copy/description of the mode rather than
    implying parity with Android's stronger guarantee.
- Cross-reference: this path already runs through
  `InboxViewModel.sanitizedCacheComponent`, so it inherits the existing
  `serverId` path-traversal guard the prior security audit noted was
  missing in *other* relay-facing call sites — no new work needed here,
  just noting the guard is already in place for this specific path.

## Feature 3 in detail: Require unlock to receive push/MFA

Off by default, same reasoning as Android: a materially different
tradeoff from feature 1, needs its own explicit opt-in and warning.

### Why this is a real tradeoff here too
Confirmed directly from `KeychainStorage.swift`'s own comment: the pairing
credential is stored `AfterFirstUnlockThisDeviceOnly` specifically *because*
`PullPollingScheduler`/`BGAppRefreshTask`/MFA-approval need to read it with
no user present. That access class means the credential is available to
the running (or backgrounded, on iOS) process at any point after the
device's first unlock post-boot — not gated by screen-lock state at all.
Anyone who can read the process's memory or invoke Keychain on the app's
behalf (jailbreak, forensic tooling, a debugger attached via a compromised
dev profile) gets the same credential whether the phone's screen is locked
or not. This is the same structural tension Android's doc describes, not a
platform-specific one — "works unattended" and "protected while locked"
are in direct conflict on both platforms, and the setting exists so the
user picks which property they want, per device.

### Implementation
- Add a second Keychain item alongside the existing pairing credential:
  the device secret, additionally wrapped with an AES-GCM layer whose key
  is protected by a `SecAccessControl` built with
  `kSecAccessControlBiometryCurrentSet` (or `.userPresence` for parity with
  the feature-1 decision to use `.deviceOwnerAuthentication`, so a Mac
  with no biometric hardware still gets password-gated protection instead
  of no protection at all) and accessibility
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Unlike Android, where the
  wrapping key is a PBKDF2 derivation from the same custom PIN as feature
  1, this platform can lean on `LAContext` + Keychain's own
  access-control machinery to do the equivalent job — consistent with the
  feature-1 decision not to build custom PIN/crypto plumbing.
- On a successful unlock (`AppLockManager.isLocked` → false), the app
  reads through this access-controlled item once — this is the one point
  where `LAContext`/Keychain may prompt Face ID/Touch ID/passcode again if
  the OS decides the existing authentication context has expired — and
  holds the decrypted device secret in memory only for the lifetime of the
  unlocked session, exactly mirroring Android's "cached key, same lifetime
  as unlocked state" design.
- The instant `AppLockManager.isLocked` flips to true, drop the in-memory
  copy. Any background pull/push/MFA attempt while locked finds only the
  access-controlled Keychain item (unreadable without user presence, which
  is unavailable to a background task by definition) and no-ops gracefully
  — `PullPollingScheduler.pollNow()` already treats `MailSourceError.notPaired`
  as non-fatal; a `credentialUnavailable`-style case should join it there,
  logged, not surfaced as an error toast. Retries on next successful
  foreground unlock, same as Android — no separate catch-up mechanism
  needed, since `PushLifecycle.onForeground()` already runs a poll on
  every foreground transition (iOS) / is the steady-state (macOS, given it
  never really "backgrounds" in the polling sense).
- When `credentialPinGateEnabled` is off (default): behavior is exactly
  what `KeychainStorage`/`SecurePairingStore` already do today —
  unconditionally available post-first-unlock, independent of
  `AppLockManager` state. No change to the default path at all.

### macOS-specific note
Because macOS effectively never "backgrounds" in the iOS sense (no
`BGAppRefreshTask`, polling runs continuously while the app is open — see
"Current architecture" above), feature 3's practical effect on macOS is
narrower than on iOS: it only matters during the window between the screen
locking (this design's chosen macOS lock trigger) and the user unlocking
again. On iOS it also covers the OS's independent background-refresh
window, which can span far longer than a locked-but-running Mac session.
Worth surfacing in the modal copy if the two platforms' behavior under
this setting ends up different enough to confuse a user who has the app on
both.

## Additional hardening included this round

### Screenshot/screen-recording protection on sensitive screens
Neither platform offers a true `FLAG_SECURE` equivalent, and the two
platforms diverge sharply here — this needs explicit, separate treatment,
not one shared mechanism:

- **macOS**: `NSWindow.sharingType = .none` on a window prevents that
  window's content from appearing in screen recordings and screen-sharing
  (e.g. via Zoom, QuickTime screen capture, `NSWorkspace`-level sharing).
  It does **not** block a system screenshot (⌘⇧3/⌘⇧4) — macOS has no API to
  prevent those. Applied to: the inbox/split-view main window, the
  pop-out "Email" window (`WindowGroup("Email", ...)`), the "New Email"
  compose window, and (once built) `UnlockView`/`SecuritySettingsView`
  panes — set on the underlying `NSWindow` via `NSViewRepresentable`/
  `NSHostingView` access, since SwiftUI has no direct `Scene`-level
  modifier for this.
- **iOS**: there is no supported API to block either screenshots or screen
  recording of arbitrary view content (this is a long-standing, deliberate
  iOS limitation, not an oversight in this design). The only mitigation
  available is *reactive*, not preventive:
  `UIApplication.userDidTakeScreenshotNotification` (detect after the
  fact — useful for logging/warning, not prevention) and
  `UIScreen.capturedDidChangeNotification` combined with
  `UIScreen.main.isCaptured` (detect an active screen recording/AirPlay
  mirror and blur sensitive content for its duration — the closest iOS
  analog to macOS's `sharingType`, but reactive rather than a standing
  property). Recommend wiring the capture-change notification to blur
  the inbox/email-detail/compose/security-settings/unlock views while
  `isCaptured` is true, and skip trying to prevent plain screenshots at
  all — attempting to "block" them (e.g. via the well-known secure-
  text-field overlay hack) is fragile, undocumented API abuse, and Apple
  has tightened against it in recent OS versions. State this platform gap
  plainly in the doc/PR rather than papering over it with a similar-
  sounding but weaker mechanism.
- Screens intentionally left unchanged: anything without sensitive
  content, matching Android's approach.

### Exclude local data from backups
No equivalent of `android:allowBackup="false"` exists as a single manifest
flag here; it is per-file/per-store on Apple platforms, and nothing in the
codebase does this today (confirmed: no `isExcludedFromBackupKey` usage
anywhere). Two things need it:
- The SwiftData store file(s) (`AppDatabase`'s default `ModelConfiguration`
  URL, normally under Application Support) — set
  `URLResourceValues.isExcludedFromBackupKey = true` on the store URL, or
  equivalently pass a `ModelConfiguration` whose backing directory has been
  marked excluded, once at first launch (and again after Hostile Location
  Protection's rebuild-on-toggle-off recreates the file).
- Any Hostile-Location-Protection-mode Quick Look temp files, belt-and-
  suspenders — the OS's `tmp` directory is not normally included in
  iCloud/Finder/iTunes backups in the first place, but excluding
  explicitly costs nothing and removes any doubt.
- Keychain items are unaffected either way: everything already goes
  through `KeychainStorage`/`SecurePairingStore` with a `ThisDeviceOnly`
  accessibility class, which Apple already excludes from device-to-device
  restore/backup by construction — no change needed there, just confirming
  it's already correct.

### Certificate pinning (TOFU, not a hardcoded pin)
Same reasoning as Android: kypost is self-hosted with a per-user `srv` URL
captured at pairing time (`SecurePairingStore.srv`), so static pinning
doesn't fit; TOFU does. Concretely, on this codebase:
- Introduce a dedicated `URLSession` (see "Current architecture" —
  `HTTPClient` defaults to `.shared` today, which cannot carry a delegate)
  built with a custom `URLSessionDelegate` implementing
  `urlSession(_:didReceive:completionHandler:)`.
- At the moment `DeviceRegistrationService`'s pairing call succeeds,
  capture the leaf certificate's SPKI SHA-256 hash from that handshake and
  store it via `SecurePairingStore` (a new field alongside `srv`, following
  the existing binding-contract comment convention in `Config.swift` for
  fields that must stay in sync across clients).
- Every subsequent relay request through the pinned `URLSession` validates
  the presented certificate's SPKI hash in the delegate callback,
  hard-failing (`.cancelAuthenticationChallenge`) on mismatch — surfaced up
  through `HTTPClient`'s existing `NetworkError` as a new case (e.g.
  `.certificateMismatch`), kept distinct from `.transport`, mirroring
  Android's "not folded into generic network error" requirement.
- Recovery path: `.certificateMismatch` gets its own UI state offering
  "Clear pairing and re-pair" (reuses the existing unpair flow already in
  `SettingsViewModel.unpair()`/`DeregisterDeviceUseCase`) — needed for
  legitimate cert rotation on the user's own server.
- Same threat model and same explicit limitation as Android: protects
  against MITM *after* pairing; does not protect the initial pairing
  handshake, which already trusts whatever `srv` URL came from the deep
  link/QR code the user scanned.

## Explicitly out of scope this round
- A custom app PIN (superseded by the `LAContext.deviceOwnerAuthentication`
  decision above) and everything that would come with one: custom lockout
  bookkeeping, PIN-change UI, PBKDF2 parameters.
- Duress/panic passcode handling (a distinct passcode that silently wipes).
- Jailbreak/tamper detection.
- Clipboard-sensitive flagging for copied fingerprints/pairing codes/QR
  payloads.
- Secure/overwrite deletion of the old on-disk SwiftData store when
  Hostile Location Protection is toggled on (plain delete via
  `FileManager.removeItem`, same as Android — recoverable via forensic
  disk recovery in principle; flagged, not fixed).
- Cleaning up the pre-existing gap that Quick Look temp files are never
  deleted today, *outside* of Hostile Location Protection mode — this
  design makes deletion mandatory only while that mode is active; doing it
  unconditionally (a general hygiene fix, independent of this feature set)
  is noted but left for a separate, smaller change.
- Any change to non-Hostile-Location-Protection attachment behavior
  (default Quick-Look-to-tmp / Save-As-via-fileExporter stays as-is).
- Attempting to block plain iOS screenshots — per the platform-gap note
  above, there is no supported API to do this; only screen-recording/
  mirroring gets a mitigation.
- Server-side work implied by the credential-tradeoff discussion (e.g.
  short-lived/rotating/scoped push tokens) — same as Android's doc, noted
  as the more fundamental fix, out of scope for a client-side design.
- The `AppEnvironment`/graph-rebuild mechanism this design proposes for
  Hostile Location Protection is described at the design level only; its
  own implementation plan (exact `@Observable` shape, how `.id(generation)`
  interacts with in-flight `Task`s and open windows/sheets on macOS) is
  substantial enough to warrant a follow-up design pass before
  implementation, not to be improvised inline with the rest of this
  feature set.
