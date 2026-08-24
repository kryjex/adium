# AGENTS.md

Fluorite is a macOS instant-messaging app. It is a Swift 6 rewrite of Adium
on top of libpurple. A SwiftUI app talks to a C bridge. The C bridge talks to
libpurple and its protocol plugins (Microsoft Teams, WhatsApp, XMPP, Matrix).

This file is the source of truth for every coding agent (Claude Code, Codex,
opencode, Gemini CLI, aider, ...). `CLAUDE.md` only imports this file. Keep the
rules here, not in tool-specific files. Tool-specific extras (hooks, subagents)
live in `.claude/` and are optional; other tools can add their equivalents.

## Build and test

- `swift build` — compile. `swift test` — run the test suite (fast, no network).
- `make app` — build `build/Fluorite.app` with plugins, Info.plist, and codesign.
- `make run` — build and open the app. `make install` — copy to `~/Applications`.
- Camera and microphone features only work from the app bundle (`make app`).
  A bare `swift run` has no Info.plist, so macOS denies media capture.
- Runtime data lives in `~/.fluorite/` (accounts.xml, logs). A rename from
  the app's former name, AdiumSwift, migrates `~/.adium-swift/` and
  `~/Library/Application Support/AdiumSwift/` in place the first time the
  renamed app launches (see `LegacyMigration.swift`); UserDefaults keys and
  the Keychain service keep their pre-rename names on purpose, so existing
  installs keep their saved accounts, preferences, and passwords.

### Identifiers that keep the old `Adium`/`adium-swift` name on purpose

These identifiers predate the rename. Do not "fix" them; each one breaks a
saved user install if you change it.

- UserDefaults keys (for example `AdiumLanguage`) — renaming loses every
  user's saved preference.
- The Keychain service `com.adiumswift.keychain` — renaming orphans every
  saved account password.
- The `LegacyMigration.swift` paths `~/.adium-swift/` and
  `~/Library/Application Support/AdiumSwift/` — these are read-only sources
  for the one-time migration into `~/.fluorite/`.
- The libpurple UI id `"adium-swift"` passed to `purple_core_init` and
  `purple_account_set_enabled` — this is the per-UI `enabled` flag stored in
  `~/.fluorite/accounts.xml`; changing it disables every saved account.
- The `.AdiumEmoticonset` / `.AdiumSoundset` pack formats — users type and
  see these exact file extensions.
- The `adiumx.com` chatlog XML namespace — required to parse classic and
  current chat logs.
- The `prpl-adium-whatsapp` protocol id — the WhatsApp plugin registers
  under this id; changing it disconnects every saved WhatsApp account.

## Architecture

- `Sources/Fluorite/` — SwiftUI app. `PurpleBridgeService` (`@MainActor`,
  `@Observable`, singleton) holds all state and receives libpurple events.
- `Sources/CLibpurple/` — C bridge over libpurple. See the C bridge rules below.
- Protocol plugins (Teams, WhatsApp) are not vendored in this repository.
  The app installs their binaries from the plugin catalog through
  `PluginManager` (see below). Propose plugin changes upstream or in the
  `adium-plugins-catalog` repository; add glue code in `Sources/`.
- `Tests/` — swift-testing (`@Suite` / `@Test` / `#expect`).
- `Sources/Fluorite/TeamsCallWindow.swift` — Teams calls open the Teams web
  client in a WKWebView. Fluorite does not implement WebRTC.
- `Sources/Fluorite/PluginManager.swift` — enables/disables plugins and
  installs them from the curated catalog. The canonical catalog lives in the
  sibling repository `adium-plugins-catalog` (plugins.json + CI that builds
  the .so binaries); the app bundles a fallback copy at
  `Sources/Fluorite/Resources/plugins-catalog.json`. Keep both in sync.
  User-installed plugins land in `~/.fluorite/plugins/`.

## Conventions

### Comments (ASD-STE100)

Write comments in English, ASD-STE100 style: short sentences, present tense,
active voice, one idea per sentence. State constraints the code cannot show.
Do not narrate what the next line does.

### i18n (required)

- Every user-facing string goes through `t("English text")`
  (`Sources/Fluorite/Localization.swift`). The key is the English text.
- Translations live in `scripts/l10n/<lang>.json`, one file per language
  (es, de, sv, nb, it, fr, ru). `es.json` defines the canonical key set.
  Regenerate the tables with
  `python3 scripts/gen-l10n.py scripts/l10n Sources/Fluorite/Resources Packaging`.
  Do not edit the generated `Localizable.strings` by hand.
- When you add a key, update every language file. Claude Code has one
  `translator-<lang>` subagent per language in `.claude/agents/`; other
  harnesses can translate directly with the rules in those files.
- The user can override the system language in Preferences > General.
  The choice persists in the `AdiumLanguage` UserDefaults key (kept from
  before the rename, see the runtime-data note above) and applies after a
  restart (`AppLanguage.bundle` resolves once at launch).
- Verify coverage with
  `python3 scripts/check-l10n.py Sources Sources/Fluorite/Resources/en.lproj/Localizable.strings`.
- Interpolations: `String` becomes `%@`, `Int` becomes `%lld`.
- Never localize values at the moment they are read from or written to
  storage: enum raw values, role ids (`member`/`admin`/`owner`), UserDefaults
  keys, handles, protocol IDs, `Picker` `.tag` values, and the `"Me"` sender
  stored in chat logs. Localize at the display site instead (`statusLabel`,
  `roleLabel`, `displayName`).
- Defaults may localize once at creation time (for example the initial contact
  groups). After creation they are user data and follow renames, not the
  locale.

### a11y (required)

- Icon-only buttons need `.accessibilityLabel(t("..."))`.
- Status indicators that carry meaning need an accessibility label.
- Purely decorative images get `.accessibilityHidden(true)`.

### Codable backward compatibility

Decode new model fields with `decodeIfPresent` plus a default. Callers use
`try?`, so a missing key would silently erase saved user data.

## Automations (any harness)

The project expects these guard rails from every agent harness. The Claude
Code implementation lives in `.claude/`; add the equivalent for your tool
(Codex, opencode, Gemini CLI, ...) and keep the intent identical.

1. **Test after every edit.** Run `swift test` after each change to a
   `.swift`, `.c`, or `.h` file and surface failures to the agent.
   Claude Code: `PostToolUse` hook in `.claude/settings.json`.
2. **Review the C bridge.** Check every change to `Sources/CLibpurple/` or the
   C callback layer of `PurpleBridge.swift` against the C bridge rules below.
   Claude Code: the `.claude/agents/c-bridge-reviewer.md` subagent holds the
   checklist; other harnesses can apply the same checklist directly.
3. **Check i18n before you finish.** Run
   `python3 scripts/check-l10n.py Sources Sources/Fluorite/Resources/en.lproj/Localizable.strings`.

### C bridge rules

- libpurple is not thread-safe. Mutate it only on the GLib loop: copy the
  arguments into a struct with `g_strdup`, schedule with `g_idle_add`, and free
  everything in the idle callback.
- Callbacks into Swift copy C strings first (`String(cString:)`) and then hop
  to the main queue with `DispatchQueue.main.async`.
- Do not keep libpurple pointers (`PurpleXfer`, request handles) after their
  destroy or close callback fires.
- Watch `PURPLE_MESSAGE_*` flag filtering: one message can surface through more
  than one signal, and a wrong filter double-delivers it.
