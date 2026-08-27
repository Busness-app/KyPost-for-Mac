# Brand Refresh: KyPost — Color Palette, Default Theme, Name, and Logo

This is a catch-up port. The web app (`llama-labels`, `frontend/`) shipped a rebrand and a
color update across several small commits on 2026-07-16 that never made it to the sibling
clients. Per `STYLE_GUIDE.md` §1 ("if a theme is added or a hex changes on one side, port it
to the other three the same day"), this doc is that port — written so a fresh Claude session
in this repo can execute it with no other context beyond the pointers below.

There are three things to bring over, independent of each other — do them in any order, but
do all three:

1. **Rename** `Llama Mail` / `llama Mail` → `KyPost` (user-visible text only).
2. **Two new theme presets** — `Patina Ky` and `Polished Ky` — plus a **new default theme**
   (was `Dark Matter`, now `Patina Ky`).
3. **New logo/icon images**, replacing the old llama wordmark/icon.

## Source of truth (already on `llama-labels` main)

- `frontend/src/theme.ts` — canonical hex values, `THEME_OPTIONS` list, `getStoredTheme()`
  default (16-field `ThemeVars`; commits `ac21016`, plus this session's default-theme change).
- `frontend/index.html`, `README.md`, `frontend/src/App.tsx` — renamed strings and logo
  wireup (commits `ac21016`, `c9d1a13`, `b237b20`).
- `ky.png` (1024×1024, repo root and `frontend/public/`) — the new primary mark, already
  wired up as the in-app sidebar logo and README image.
- `ky50p.png` (512×512, repo root) — smaller variant, currently used only in the README.
- `kypost.png` (1024×1024, repo root and `frontend/public/`) — an alternate/full-res source
  image, not referenced by any running code; available if you want a second source to
  regenerate icon sizes from.
- `frontend/public/favicon.png` (32×32) and `frontend/public/apple-touch-icon.png` (180×180)
  — already regenerated from the new mark.
- `frontend/public/pwa-icon.svg` — **do not port this one.** It's a leftover hand-drawn
  monogram in the old Dark Matter colors (`#1a1a1e`/`#c29a72`), still referenced from
  `manifest.webmanifest` but no longer linked from `index.html`. It predates the rebrand and
  was never redrawn to match `ky.png`. Treat `ky.png` as the only source-of-truth mark.

## Part 1 — Rename: "Llama Mail" → "KyPost"

Web's rename (commit `ac21016`) touched only user-visible strings: page `<title>`, PWA
manifest `name`/`short_name`, the sidebar `alt` text, the About/license panel's app-name
span, and the service-worker's default push-notification title. It did **not** touch any
internal identifier. Mirror that scope here — rename what a user reads, leave identifiers
alone (see "Explicitly deferred" below).

Known anchors per platform (grep for `Llama Mail` / `llama Mail` case-insensitively to catch
anything not listed — these lists aren't guaranteed exhaustive):

**Android (`llama-mobile`)**
- `app/src/main/res/values/strings.xml`: `app_name`, `welcome_message`, `inbox_heading`,
  `about_title` all contain `Llama Mail` / `llama Mail` → `KyPost`. `about_body`
  ("Developed by Busnes Games...") has no brand name in it — leave it.
- Check `AboutDialog.kt` for any place it concatenates `about_title` with other brand text.

**iOS/macOS (`llama-Mail-for-Mac`)**
- `llama Mail for Mac.xcodeproj/project.pbxproj`: `INFOPLIST_KEY_CFBundleDisplayName` and
  `PRODUCT_NAME` are both set to `"llama Mail"` in (at least) two build configs — search/replace
  all occurrences, not just the first match.
- `Info.plist`: `NSCameraUsageDescription` ("llama Mail uses the camera...") and
  `NSContactsUsageDescription` ("llama Mail exports your synced contacts...") are shown to
  the user in system permission prompts — update the brand name inside the sentence, keep
  the sentence itself.
- `Info.plist`'s `CFBundleURLName` is `"Llama Mail Pairing"` — cosmetic (not user-facing in
  normal use), but update it for consistency.
- Grep `Presentation/` and any About/Settings screen for a literal `"Llama Mail"` /
  `"llama Mail"` string used as display text.

**Linux (`llama-Linux`)**
- `packaging/flatpak/com.urlxl.LlamaMail.desktop`: `Name=Llama Mail` → `Name=KyPost`.
- `packaging/flatpak/com.urlxl.LlamaMail.metainfo.xml`: `<name>Llama Mail</name>` and the
  `<summary>`/`<description>` prose that says "Llama Mail is a relay-only email client...".
- `packaging/flatpak/LlamaMail.notifyrc` — check for a display-name field.
- Grep `app/qml/` (`Settings.qml`, `MobileRoot.qml`, `DesktopRoot.qml`) for visible
  `"Llama Mail"` text in About/Settings UI.
- `app/main.cpp:623` — `pushConnector.registerClient(QStringLiteral("Llama Mail push
  notifications"))`. Check whether this string is ever shown to a person (e.g. surfaced in a
  paired-devices list on another client) or is purely an internal log/registration label; if
  the former, rename it, if the latter, leave it (it's closer to an identifier than a name).

**Done since this document was written — the identifier rename went ahead:**
- Android's `applicationId` is `org.kysecurity.mail` (`app/build.gradle.kts:81`), with
  `.github` and `.fdroid` suffixes per channel.
- The Apple bundle ID is `org.kysecurity.mail` too, along with the Keychain access group,
  the `BGTaskScheduler` identifier and the Secure Enclave key tag. It had to happen before
  the first App Store submission: a bundle ID is the store record and cannot be changed
  after the first release. Nobody had an install to break, which is what made it cheap.

**Explicitly deferred — do not rename these:**
- The flatpak app ID `com.urlxl.LlamaMail` (and its icon filenames / `desktop-id`).
- The deep-link URL scheme `llamalabels` (Config.swift, Info.plist `CFBundleURLSchemes`,
  Linux `main.cpp`'s scheme check).
- Qt's `app.setApplicationName(QStringLiteral("LlamaMail"))` in `main.cpp` — this is the
  `QSettings` storage path, not display text; renaming it silently relocates every user's
  local settings.
- Storage/preference keys: `THEME_STORAGE_KEY` (`"llama-lab-theme"` on web/Android),
  Android's `SharedPreferences` name `"com.urlxl.mail.settings"`, and any equivalent
  `UserDefaults`/`QSettings` key on iOS/Linux.
- The web app's npm package name `llama-lab-frontend` (not relevant here, listed for parity).

These are all structural identifiers, not brand text — changing any of them is a separate,
higher-stakes decision (breaks existing installs, orphans local settings, needs a new store
listing) and should go back to the user explicitly rather than being bundled into this rename.

"Developed by Busnes Games" stays unchanged everywhere it appears.

## Part 2 — Two new theme presets + new default

Web's `THEME_OPTIONS` grew from 13 to 15 entries (commit `ac21016`), appending two themes at
the end of the existing list — same order, same names, on every platform:

```
Dark Matter, Light Matter, Tropics, Tropic Night, Ocean, Coffee, White Cliffs,
Cyber Punk, Neon Purple, Space, Sky, Forest, Sun, Patina Ky, Polished Ky
```

And as of this session, web's default theme (`getStoredTheme()`'s fallback in `theme.ts`)
changed from `Dark Matter` to **`Patina Ky`** — port that too. `STYLE_GUIDE.md` §1 currently
says "13 named themes... default `Dark Matter`"; update that line once you've ported the
themes (only `llama-mobile` has a copy of this file today — skip if this repo doesn't have
one).

### Hex values

Below, each platform's fields are given in the order its own `ThemePalette` type already
uses (verified against the current source in each repo). Copy these literally — don't
re-derive them from each other, to avoid transcription drift.

**Web (`ThemeVars`, reference only — already shipped, nothing to do here):**

| Field | Patina Ky | Polished Ky |
|---|---|---|
| bg | `#0d0f14` | `#eef2f6` |
| panel | `#161a22` | `#ffffff` |
| ink | `#64748b` | `#475569` |
| inkStrong | `#e2e8f0` | `#0f172a` |
| accent | `#4deeea` | `#0891b2` |
| accentSoft | `#0e4a48` | `#cffafe` |
| line | `#1e293b` | `#cbd5e1` |
| sidebarStart | `#0d0f14` | `#f1f5f9` |
| sidebarEnd | `#1b212c` | `#e2e8f0` |
| newEmailBorder | `#0e9668` | `#059669` |
| newEmailStart | `#4deeea` | `#0891b2` |
| newEmailEnd | `#10b981` | `#10b981` |
| newEmailText | `#04120d` | `#042f2e` |
| buttonText | `#04120d` | `#042f2e` |
| linkBorder | `#94a3b8` | `#64748b` |

**iOS/macOS (`AppTheme.swift`, `ThemePalette(bg:panel:ink:inkStrong:accent:accentSoft:line:)`)
and Linux (`AppTheme.cpp`, `ThemePalette{bg, panel, ink, inkStrong, accent, accentSoft, line}`)
— identical 7-field shape, 1:1 with web's matching fields:**

```
"Patina Ky":   bg=0x0D0F14  panel=0x161A22  ink=0x64748B  inkStrong=0xE2E8F0
               accent=0x4DEEEA  accentSoft=0x0E4A48  line=0x1E293B

"Polished Ky": bg=0xEEF2F6  panel=0xFFFFFF  ink=0x475569  inkStrong=0x0F172A
               accent=0x0891B2  accentSoft=0xCFFAFE  line=0xCBD5E1
```

(Swift uses `Color(hex:)` literals matching `theme.ts`'s hex strings; Qt/C++ uses `quint32`
`0xRRGGBB` literals matching `AppTheme.cpp`'s existing rows — use whichever literal style the
surrounding rows in each file already use.)

**Android (`AppTheme.kt`, `ThemePalette(bg, panel, ink, inkStrong, accent, line,
avatarGradientStart, avatarGradientEnd, avatarBorder)`)** — 6 direct fields plus 3
avatar-gradient fields Android derives from web's `newEmailStart`/`newEmailEnd`/
`newEmailBorder` (this is the existing pattern for every other row in the table — Android has
no `accentSoft` field, see `STYLE_GUIDE.md` §1):

```kotlin
"Patina Ky" to ThemePalette("#0d0f14", "#161a22", "#64748b", "#e2e8f0", "#4deeea", "#1e293b", "#4deeea", "#10b981", "#0e9668"),
"Polished Ky" to ThemePalette("#eef2f6", "#ffffff", "#475569", "#0f172a", "#0891b2", "#cbd5e1", "#0891b2", "#10b981", "#059669"),
```

### Default theme change

Change the fallback/default from `"Dark Matter"` to `"Patina Ky"` at each of these spots
(don't touch the theme *definitions* themselves, just the fallback value):

- **Android** `AppTheme.kt`: `getStoredThemeName()`'s `prefs.getString(THEME_STORAGE_KEY,
  "Dark Matter") ?: "Dark Matter"` (both literals) and its `if (...) saved else "Dark
  Matter"`; `themePaletteFor()`'s `?: themePalettes.getValue("Dark Matter")`.
- **iOS/macOS** `AppTheme.swift`: `static let defaultThemeName = "Dark Matter"`.
- **Linux** `AppTheme.cpp`: `defaultThemeName()`'s `return QStringLiteral("Dark Matter");`.

Leave the `"Dark Matter"` theme *definition* itself untouched in all three — it's still a
valid selectable preset, just no longer the default.

## Part 3 — Images

Copy the new mark over from `llama-labels` (paths above) into this repo's equivalent asset
locations, replacing the old llama wordmark/icon:

- **Web-mirrored static assets** (repos that keep a `public/`-style copy of web's assets,
  e.g. `llama-Linux/public/`): copy `ky.png`, `ky50p.png`, `favicon.png`,
  `apple-touch-icon.png` over their old (`llamalabel.png`/`llamalabels.png`-named) equivalents
  and update whatever references them (`.desktop` `Icon=`, QML `Image` sources, etc.). Do
  **not** port `pwa-icon.svg` (see "source of truth" note above).
- **Real app icons** (Android adaptive/launcher icons in `mipmap-*`, iOS
  `Assets.xcassets/AppIcon.appiconset`, Linux's flatpak `packaging/flatpak/icons/hicolor/*/apps/
  com.urlxl.LlamaMail.png` + `.svg`): these need to be regenerated at each platform's required
  sizes from the new 1024×1024 `ky.png` (or `kypost.png` as an alternate full-res source), not
  just file-swapped — the old assets are a different (llama) mark entirely, at
  platform-specific sizes/formats (webp, `.icns`, multi-size `.png` set). Which tool you use
  to regenerate them (Android Studio's Image Asset wizard, `iconutil`/`sips`, ImageMagick,
  etc.) is up to you — not prescribed here.
- **In-app logo usage** (e.g. a splash screen, About screen, or sidebar logo, if this app has
  one): point it at the new mark, same as web's `App.tsx` sidebar logo now points at
  `/ky.png`.

## Explicitly deferred

- Exact icon-regeneration tooling/workflow for each platform (see above).
- Any UI layout changes to accommodate a different-shaped logo — the new mark is the same
  square/circular monogram shape as the old one, so no layout changes should be needed, but
  verify.
- Whether to also rename any of the "explicitly deferred" identifiers in Part 1 — that's a
  separate decision, raise it with the user rather than doing it here.

---

## Verification (manual)

- [ ] App name shown in the OS (home screen label / Dock / app switcher / About screen) reads
      "KyPost", not "Llama Mail".
- [ ] Any system permission-prompt strings that mention the app by name say "KyPost".
- [ ] Theme picker shows 15 options including "Patina Ky" and "Polished Ky" at the end of the
      list, and their colors visually match the web app's versions of the same themes
      side-by-side.
- [ ] A fresh install (or cleared local storage/prefs) launches into "Patina Ky", not "Dark
      Matter".
- [ ] Switching to "Dark Matter" (or any other pre-existing theme) still works exactly as
      before — this change only touched the default, not the other palettes.
- [ ] App icon / launcher icon / Dock icon shows the new `ky.png` mark, not the old llama.
- [ ] Any in-app logo (splash/About/sidebar) shows the new mark.
- [ ] Package/bundle identifiers, deep-link scheme, and local settings storage are unchanged
      — existing installs should update in place without losing saved settings or becoming a
      "new" app to the OS.
