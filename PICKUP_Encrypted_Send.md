# Pickup — Encrypted Send from a Paired Client

Handoff note for continuing this work in Xcode. Written 2026-07-26, after the
`client-encrypted-send` branch was merged to `main`.

Implements `Client_Encrypted_Send.md`. Plan and per-task breakdown:
`docs/superpowers/plans/2026-07-26-client-encrypted-send.md`.

## Read this first

**Not one line of this feature has ever been compiled or run.** It was written
on a Linux machine with no Swift toolchain — `xcodebuild` and `swift` were both
absent. Every task's TDD steps were marked UNRUN. ~40 new tests exist and none
has executed. Verification throughout was reading and hand-tracing by
implementers and independent reviewers.

That is not a hypothetical risk. The final whole-branch review found a probable
hard build error (`pgpKeyCustody`'s missing `return`, since fixed) that nine
per-task reviews had missed, precisely because no compiler ever looked at it.

**Your first `xcodebuild test` is the real gate.** Treat everything below as
unverified until it passes.

```sh
xcodebuild test -scheme "KyPost" -destination 'platform=macOS'
```

Narrow while iterating:

```sh
xcodebuild test -scheme "KyPost" -destination 'platform=macOS' \
  -only-testing:'KyPost Tests/PgpSendTests'
xcodebuild test -scheme "KyPost" -destination 'platform=macOS' \
  -only-testing:'KyPost Tests/MailTests'
```

## If the build fails, look here first

These are the constructs no compiler has checked, ranked by how much doubt
survived review:

1. **`KyPost Tests/PgpSendTests.swift`** — `NSDictionary(dictionary:) ==`
   inside `#expect`, and the `ComposeStub` routed-transport helper. The
   `@Suite @MainActor struct` suites call `async` view-model methods.
2. **`KyPost/Presentation/Screens/ComposeView.swift`** — the
   `confirmationDialog(_:isPresented:titleVisibility:presenting:actions:message:)`
   overload. Parameter types were checked by hand against the view model, not
   by a compiler.
3. **`KyPost/Presentation/Shared/ViewModels/ComposeViewModel.swift`** — `await`
   inside a ternary branch (`keylessWarning = encrypt ? await … : []`), and
   `nonisolated struct PendingPickup`.
4. **`KyPost/Domain/Models/PgpKeyCustody.swift`** — `return switch …`. If any
   other `switch`-expression body in the branch is missing its `return`, this is
   the shape to grep for.
5. **Actor isolation generally.** The target sets
   `SWIFT_DEFAULT_ACTOR_ISOLATION` to MainActor, so anything new that crosses
   an isolation boundary is a candidate.

## Manual verification (nothing below was ever seen on screen)

Compose window, `⌘N`:

- **Server-custody account** — Encrypt and Sign toggles appear.
- **Client-custody account** — no toggles; a handoff row with "Encrypt in
  webmail…" instead.
- **No PGP identity, or bootstrap unreachable** — neither appears. This is also
  what you will see until the server branch lands (see below), so an empty row
  is the *correct* observation today, not a bug.
- **Keyless confirmation dialog** — title "Send an unencrypted link?", every
  address named, "7 days" and "unencrypted" both present, Cancel is the default
  action (Return should cancel, not send).
- **Warning on a 200** — the window stays open with the notice and Send is
  disabled. It must not dismiss over the notice.
- **Handoff** — saves a draft, opens the system browser at
  `/read?mailbox=Drafts`. Never an in-app web view.

To see the toggles before the server side exists, temporarily hard-code
`custody = .serverHeld` in `PgpSendService.init` — and revert it.

## Server dependency

Every endpoint this feature calls lives on `kypost-server` branch
`feat/mobile-encrypted-send`, **unmerged and undeployed**. Until it lands:

| Call | What happens today |
|---|---|
| `GET /api/pgp/bootstrap` | 404 → custody stays nil → no PGP row. Clean. |
| `POST /api/pgp/recipients/check` | 404 → caught, warns about nothing. Clean. |
| `POST /api/mail/send` + new flags | Unknown JSON keys ignored; plaintext send is byte-identical to before this branch. Clean. |
| `POST /api/mail/draft` | 404 → "Couldn't save this as a draft: The server returned an error (status 404)." Nothing lost; the message stays in the compose window. |

A 404 means the branch hasn't landed, not a client bug.

## Open decisions

### 1. The preflight warning is never seen — needs a call

`ComposeViewModel.send()` runs the recipient preflight, then delivers. On a
clean send `didSend` fires and the window dismisses over the warning; on a 409
the dialog covers it. The only path where it is visible is the
`pickupFallbackAvailable: false` refusal, where it duplicates the error text.

The spec's intent is explicit — "Ask before sending, so the 409 below is a
confirmation rather than a surprise" and "surface addresses with `hasKey: false`
as an inline, non-blocking warning". As built, the preflight is a network round
trip on every encrypted send that shows the user nothing.

Note `theKeylessPreflightWarnsWithoutBlocking` asserts both the warning *and*
`didSend`, so it currently encodes this behavior as expected.

**Fix:** run the preflight when Encrypt flips on and when the committed
recipient set changes, debounced — reuse the existing `debounceInterval` /
`searchTask` pattern already in `ComposeViewModel`. Keep the send-time call too;
it just cannot be the only one. ~20 lines.

This was left undone deliberately: the plan's Task 7 explicitly chose "one call
site, YAGNI", so changing it is a scope decision, not a bug fix.

### 2. Nothing in a 200 confirms encryption happened — server-side

Against a server that serves `/api/pgp/bootstrap` (it already exists for the
browser) but does not yet honour the send flags, this build shows Encrypt, sends
`encrypt: true`, has the field ignored, sends plaintext, and reports success.
The user has no way to know.

There is no client-side fix. The 200 body needs to echo what the server did
(e.g. `"encrypted": true`), and this client should then treat `encrypt: true`
plus an absent or false echo as a warning-level notice. **Worth raising with the
server team before `feat/mobile-encrypted-send` merges, while the contract is
still editable.**

### 3. `PgpSendService`'s location

It is an `@Observable @MainActor final class` in `KyPost/Domain/UseCases/`,
where every sibling is a stateless `struct`; observable session state otherwise
lives only in `Presentation/Shared/ViewModels/`. The final reviewer recommends
moving it there (a pure file move — one module, no code change) and renaming it
for what it is.

**If you touch it, know that `@Observable` is load-bearing.**
`ComposeViewModel.pgpCustody` is a computed passthrough to `pgp.custody`;
observation tracking that read during `body` evaluation is the only reason the
toggles appear after bootstrap resolves. Refactor it to a `struct` and the
toggles never appear.

If you leave it where it is, write the exception into
`KyPost/Presentation/AGENTS.md` so the next reader doesn't "clean it up".

### 4. The plan document has stale snippets

`docs/superpowers/plans/2026-07-26-client-encrypted-send.md` still carries three
code blocks that the implementation deliberately diverged from:

- Task 1 Step 3 — coalesces `protection: nil` to `""`, contradicting its own
  test. The shipped code is right: `nil` (absent/unknown) → `.clientHeld`, `""`
  (explicitly no identity) → `.noIdentity`.
- Task 7 / Task 8 — the old `confirmPickupFallback()` no-arg signature and the
  old dialog code, both superseded by the fix for the Critical below.
- Task 9 — README wording claiming there is "no drafts folder". There is one;
  the real gap is the compose-side affordance.

Amend or leave as historical record, but don't implement from those blocks.

## Known-deferred minors

None blocks a merge. Roughly in order of worth-doing:

| Where | What |
|---|---|
| `PgpSendService` | `custody` is cached for the process lifetime with no invalidation on re-pair. Unpair, pair a different account, and compose shows the old account's toggles until relaunch. A two-line `invalidate()` on the deregister path would close it. |
| `RelayMailSource.conflictError` | No test pins precedence when a 409 body carries both `clientSideNeeded` and `keylessRecipients`. The code takes `clientSideNeeded` first, which is the safer read; a three-line test would pin it. |
| `ComposeView` | `pgpControls` pops in after the bootstrap round trip, shifting the editor down mid-compose. Reserving the row's height while custody is nil would avoid it. |
| `PgpSendTests` | `aBadServerUrlFailsBeforeAnyRequest` covers only `fetchBootstrap`'s guard, not `checkRecipients`' identical one. |
| `PgpSendService` | Two overlapping `loadIfNeeded()` calls can both pass the `custody == nil` guard and issue two GETs. Harmless — idempotent read, same result. `DeviceRegistrationService`'s `inFlight` dedup is the pattern if it ever matters. |
| `ComposeViewModel` | `cancelPickupFallback()` doesn't clear `noticeMessage`. Safe today only because callers clear it before `pendingPickup` can be set — an implicit invariant across three files. |
| `RelaySendRequest.init` | `let pgp = pgpFlags` is a needless rebinding. |
| `ComposeViewModel:21` | `ComposeAttachment` is a pure value type not declared `nonisolated`, which `Presentation/AGENTS.md` says is a must. Pre-existing. |
| Repo-wide | `Log` call sites use `.error` with no `privacy:` argument, so `os.Logger` redacts their dynamic interpolations to `<private>`. `PgpSendService` uses `privacy: .public` and is arguably the correction — worth a repo-wide decision. |

## Commit map

| Commit | What |
|---|---|
| `c326878` | Spec + implementation plan |
| `41e0b75` | `PgpKeyCustody` — the custody rule |
| `e21adc1` | `PgpSendClient` — bootstrap + recipient check |
| `8a97129` | `encrypt`/`sign`/`allowPickupFallback`; `send` returns the relay `warning` |
| `21c2fa4` | The keyless-recipients 409 |
| `382b5bd` | `POST /api/mail/draft` + the webmail Drafts link |
| `8ca1dc4` | `PgpSendService` — session custody cache + preflight |
| `1bb42a5` | ComposeViewModel: confirmation, re-send, handoff |
| `9dfb57b` | Task 7 review fixes |
| `2896787` | ComposeView: toggles, dialog, notice, handoff |
| `81700bc` | Documentation |
| `9afb876` | Whole-branch review fixes (both Criticals + four minors) |

The two Criticals in that last commit are worth knowing about, because both were
invisible to per-task review and only appeared when someone read the whole
branch at once:

1. **"Send link anyway" did nothing.** The dialog's `isPresented` setter nils
   `pendingPickup` synchronously on dismissal, while the button's action runs
   later inside a `Task` and read that same value. Confirming sent nothing,
   showed no error, and pressing Send again re-entered the same 409 loop. Every
   unit test passed, because they all called `confirmPickupFallback()` directly
   and never went through the binding. Now fixed with the `presenting:` overload
   and a regression test.
2. **`pgpKeyCustody` was missing its `return`.** Implicit return applies only to
   single-expression bodies; this one has two `guard`s first.

## Do not build

From the spec, and still binding:

- Any OpenPGP implementation, key generation, or key unwrapping in this client.
  This client never holds the account's private key. The reasoning is in
  `Client_Encrypted_Send.md` under Scope — the earlier plan that called for
  bundling GnuPG is superseded and should not be revived without a conversation.
- Any call to `POST /api/pgp/recipients/resolve`, `POST /api/pgp/pickup`, or
  `POST /api/mail/send-pgp`.
- A remembered "always allow pickup fallback" preference. The opt-in is
  per-message by design.
