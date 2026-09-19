# CLAUDE.md

Notes for Claude Code sessions working in this repo.

## Build, run, test

```bash
swift test --disable-xctest       # the whole suite, ~0.05s
./build.sh                        # -> build/Cashew.app (universal, ad-hoc signed)
./build.sh --dmg                  # also -> build/Cashew.dmg
./build.sh --dmg-only             # DMG around the existing app, without rebuilding it
open build/Cashew.app
ls build/Cashew.app/Contents/Helpers/   # cashew-hook, the Claude Code hook helper
pkill -f "MacOS/Cashew"         # stop it (menu bar app; there's no window to close)
```

`--dmg-only` is what the release procedure uses: the app is signed with a Developer ID, notarized and
stapled before it goes into the image, and rebuilding at that point would throw all of that away.

`swift run` does not work and is not meant to — it produces a bare binary with no `Info.plist`, so
`LSUIElement`, `SMAppService.mainApp`, and notification registration all misbehave.

There is no Xcode project. SwiftPM compiles the sources and `build.sh` wraps the result in a bundle.

**`main` is protected, so don't commit to it.** Branch, push, and open a PR — a direct push is
rejected with `GH006: Protected branch update failed`, and the rule applies to admins too, so there
is no override to reach for. The `build` check has to be green before the PR can merge, which means
`swift test --disable-xctest` locally first. `CONTRIBUTING.md` has the same rules for humans.

## Architecture

| File | Responsibility |
|---|---|
| `Sources/Cashew/main.swift` | Six lines of top-level code for the menu bar app. Top-level code can't live in a library target, so this and `cashew-hook`'s `main.swift` are the only two files outside a library |
| `Sources/cashew-hook/main.swift` | The Claude Code hook helper. Top-level code only; reads the hook payload, writes one session file, exits 0. Bundled at `Contents/Helpers/` |
| `Sources/CashewShared/` | Foundation-only code shared by the app and the helper: `SessionRecord` and its files, `HookEvent` (the hook → state machine), `SessionOwner`, `isJSONBoolean`. Must never import AppKit — the helper runs on every tool call |
| `Sources/CashewCore/AppDelegate.swift` | Wires provider → menu, owns the poll timer and the 60s countdown tick, refreshes on wake. The **only** public symbol in the module |
| `Sources/CashewCore/MenuController.swift` | The status item: menu bar title, dropdown, Settings submenu. Knows nothing about where usage comes from |
| `Sources/CashewCore/UsagePanel.swift` | The dropdown's SwiftUI rows, and the pure `UsageRow` view model behind them. Which limits reach the *menu bar title* is `TitleSelection`, in MenuController.swift |
| `Sources/CashewCore/UsageAPI.swift` | `LimitWindow` model, `UsageProvider` protocol, `ClaudeProvider` (endpoint client + all response parsing) |
| `Sources/CashewCore/Credentials.swift` | Token discovery across the login Keychain and the credentials file, ranked rather than first-wins |
| `Sources/CashewCore/Format.swift` | Percentages, countdowns, locale-aware clock times, the colour modes, the menu bar spark image. `clock` is for *future* dates and `stamp` for past ones — they are not interchangeable, see below |
| `Sources/CashewCore/Settings.swift` | UserDefaults-backed preferences; launch-at-login proxies `SMAppService` |
| `Sources/CashewCore/Notifier.swift` | Threshold alerts, deduplicated per window per reset period |
| `Sources/CashewCore/UsageHistory.swift` | Everything Cashew writes to disk: the rolling samples the forecast reads, and the last good reading so a failed cold start still has rows. Location is injected so tests never reach the real one |
| `Sources/CashewCore/StatuslineFeed.swift` | Plan usage read from what Claude Code hands its statusline, when the user has opted in. Read-only — the feed never writes the file or touches `~/.claude/`; hook installation is `HookInstaller`'s, and only for its own hooks. Also owns the setup snippet and the status shown in Settings; the README quotes the snippet and a test holds the two together |
| `Sources/CashewCore/Forecast.swift` | Pure burn-rate projection over those samples, and the rule for which forecasts colour the title |
| `Sources/CashewCore/HookInstaller.swift` | Adds/removes Cashew's hooks in `~/.claude/settings.json` and nothing else |
| `Sources/CashewCore/SessionActivity.swift` | Reads session files: liveness, the no-owner age limit, interrupt detection, ordering. Owns the session menu copy |
| `Sources/CashewCore/TranscriptTail.swift` | Esc-interrupt detection from the end of a transcript |
| `Sources/CashewCore/GitBranch.swift` | Branch from `.git/HEAD`, following worktree `gitdir:` files |
| `Sources/CashewCore/StatusWords.swift` | The phrase book: what Cashew *says* a session is doing, for the menu bar and the dropdown alike |
| `Sources/CashewCore/SessionPanel.swift` | The `CLAUDE CODE` dropdown rows and their pure `SessionRow` view model |
| `Sources/CashewCore/DirectoryWatcher.swift` | Debounced `DispatchSource` on the sessions folder |
| `Sources/CashewCore/UpdateCheck.swift` | Once-a-day GitHub Releases check; version comparison and release parsing |
| `assets/Cashew.icon` | Icon Composer document — the icon's source of truth. One layer, `cashew.png`, over a cream gradient, with the shadow and material macOS 26 supplies |
| `assets/icon-1024.png` | A committed *render* of that document, and the only icon input on the CLT-only path |
| `assets/render-icon.sh` | Regenerates the PNG from the document. Run it after editing the icon, commit both |
| `assets/README.md` | What belongs in `assets/` — screenshots, the hero GIF, and the icon sources |

**`Fmt.clock` renders *future* dates; `Fmt.stamp` renders past ones.** Not a style preference — clock
chooses its weekday format with `date.timeIntervalSince(now) >= dayThreshold`, which is only ever true
looking forward, so a past date always came out as a bare time. "Showing data from 4:44 AM" sat above
"Refresh Now (15d ago)" for two weeks, describing the same instant and disagreeing. Reset times are
future and use `clock`; anything describing when data was fetched is past and uses `stamp`.

Everything lives in `CashewCore` so the test target can reach it with `@testable`, keeping the
public API to `AppDelegate` alone. `MenuController` renders `[LimitWindow]` and nothing else — that's
what makes adding a second provider one new file, so don't put Claude-specific strings in it.

`Package.swift` pins `swiftLanguageModes: [.v5]`. Swift 6 mode rejects the static mutable state in
`Notifier`; moving to `.v6` means annotating those, not just flipping the line. `platforms:
[.macOS(.v13)]` is load-bearing — it, not the triple, is what pins the deployment target.

## Hard rules

1. **Never print, log, or commit the OAuth token**, or the contents of the credentials file. Not in
   debug output, not in error messages, not in CI. `.github/workflows/build.yml` greps for this.
2. **Zero third-party dependencies.** AppKit, SwiftUI, Foundation, Security, UserNotifications,
   ServiceManagement. `Package.swift` has no `dependencies:` array and never should. Tests use
   swift-testing, which ships with the toolchain — **not XCTest**, which is absent from the Command
   Line Tools and would break the CLT-only build contract.
3. **All parsing of the usage endpoint must be defensive.** It is undocumented and it drifts.
   Missing, null, or wrong-typed fields drop that *one* row and render `–`. Never force-unwrap a
   field from the response; never throw on a shape you didn't expect.
4. **No secrets in the repo, and no notarization machinery in `build.sh`.** It signs ad-hoc by
   default and may use `$CASHEW_SIGN_ID` — an identity name, resolved from the developer's own
   Keychain — but it must never contain or handle a certificate, an app-specific password, or
   anything notarization needs. Releasing stays a manual maintainer step (`docs/RELEASING.md`), and
   CI signs ad-hoc and drafts the release for a signed build to replace.
5. **Two network destinations:** `api.anthropic.com` for usage, and `api.github.com` for a
   once-a-day update check the user can turn off. No analytics, no identifiers, no downloads.
6. **Cashew edits `~/.claude/settings.json` only to add or remove its own hooks** — entries whose
   command runs the bundled `Contents/Helpers/cashew-hook`. Never another key, never another tool's hook, never
   `statusLine`. It never writes a file it could not parse, never replaces a symlink, writes only
   when something changed, and backs the original up once to `settings.json.bak-cashew`.

## The response shape

The endpoint returns two overlapping shapes, and `ClaudeProvider.windows(in:)` reads both:

- **Preferred:** a `limits` array of `{kind, percent, resets_at, scope}` where `kind` is `session`,
  `weekly_all`, or `weekly_scoped`. Scoped entries name their own model in
  `scope.model.display_name`, which is why the third row says "WEEKLY · FABLE" rather than
  hardcoding Opus.
- **Legacy:** top-level `five_hour`, `seven_day`, `seven_day_opus` with `utilization` / `resets_at`.
  Used to fill in anything the array didn't provide, **per field**.

Four traps, each with a regression test — don't "simplify" any of them:

- **`resets_at` is re-stamped on every request.** Three polls twenty seconds apart came back with
  fractional seconds `.516073`, `.880178`, `.202674` for the same reset. `Notifier.periodID`
  therefore quantizes to a rounded minute; keyed on the raw timestamp, every poll looked like a new
  period and alerts fired on every single poll. Windows are ≥5 hours apart, so the bucket can never
  merge two real periods.

- **Cast `limits` to `[Any]` and filter, never to `[[String: Any]]`.** A conditional cast to an array
  of a concrete element type checks every element and yields nil if one fails, so a single
  unrecognized entry would discard the whole array instead of itself.
- **JSON booleans bridge to `NSNumber`.** `as? Double` on `true` succeeds and gives 1.0, so
  `{"percent": true}` reads as 1% unless the CoreFoundation type id is checked. `as? Bool` is not a
  substitute: `NSNumber(42) as? Bool` also succeeds. The shared `isJSONBoolean` guard is used by the
  usage parser *and* by `Credentials` when reading `expiresAt`.
- **Two ISO8601 formatters are required.** Timestamps arrive as
  `2026-08-02T16:39:59.408408+00:00`; `ISO8601DateFormatter` needs `.withFractionalSeconds` for
  those and returns nil without it, and returns nil *with* it for timestamps that lack them.

**`percent` is an integer, and that is a trap for anything that fits a rate to it.** One point is the
smallest change the endpoint can express, so it carries about half a point of rounding. `Forecast`
therefore requires the samples to span at least a quarter of their trailing window *and* to move more
than one point — sample *count* is not observation *time*. Without both, the first real run produced
five weekly samples over 22 minutes, one point of movement, and announced "on pace to hit the limit
~Sat 1:44 AM" for a limit sitting at 2%. Mutation testing is what proved the movement floor does
anything at all: the obvious fixtures for it were being caught by the idle threshold instead, and only
a nearly-full window isolates it.

**429 is not just another status code, and treating it as one cost fifteen days of a dead menu bar.**
An instance was rate-limited, kept polling every five minutes because `reschedulePoll` only ever knew
one interval, and had no route back except the user noticing and restarting it. Meanwhile the account
was fine — a fresh process using the same token got `200` immediately, which is how it was diagnosed.
So `UsageError.rateLimited` carries the `Retry-After` the parser used to discard (RFC 9110 allows
seconds *or* an HTTP date, and a date already in the past must yield nil rather than a negative wait),
and `Backoff.delay` turns it into a schedule. Don't fold it back into `.http`.

**Staleness is a display rule, not a storage one.** Keeping the last good numbers when a poll fails is
right for a short outage and wrong for a long one. `Freshness.displayable` is the single definition —
used by the panel, the menu bar title, the error copy *and* `restorableSnapshot`, so a reading can't
be too stale to keep showing yet fresh enough to restore. The per-window "its reset has passed" rule
alone is not enough: the real failure had `resets_at` nil on every row, so only the age bound caught
it.

Values are also clamped to 0–100 and checked for finiteness, because `Fmt.pct` converts to `Int` and
that traps on infinity or anything past `Int`'s range. `scope.model.display_name` is server-controlled
and lands in a menu label, a notification title *and* a `UserDefaults` key, so it is trimmed,
flattened, length-capped, and rejected when empty.

## Why the dropdown's rows are custom views

A menu item that isn't a command has to be disabled, and macOS draws disabled items dimmed — which is
why the panel used to look washed out. The informational rows are therefore SwiftUI views in
`NSMenuItem.view`, which AppKit does *not* dim, while `NSMenu` still supplies the material, the
dismissal behaviour and key equivalents for the real commands.

Four things were measured before committing to this, and each would have sunk it:

- **SwiftUI does repaint while a menu is tracking.** Reassigning `NSHostingView.rootView` updates the
  row on screen mid-tracking, which is what lets `refreshLiveRows` keep working. If it had deferred
  until tracking ended, held-open menus would have silently frozen again.
- **`isEnabled = false` does not dim a custom view** — only the item's own drawing. So these rows can
  be inert without going grey.
- **`title` still reaches AppleScript and VoiceOver on a view-backed item**, so `NSMenuItem.hosting`
  sets it and the `osascript` recipe below still works. Set it on every view-backed row.
- **Sizing** needs `hostingView.frame.size = hostingView.fittingSize`, or the item lays out at zero
  height on first display. The SwiftUI frame is `minWidth`/`maxWidth: .infinity`, not a fixed width,
  and the hosting view carries `autoresizingMask = [.width]`: AppKit sizes the menu from the widest
  item and adds ~65pt of its own chrome, but lays the view out at x=0 without stretching it, so a
  fixed-width row leaves that chrome as dead space and the separators visibly overrun the text.

`NSApp.appearance` does **not** drive menu rendering, so dark mode can only be checked by switching
the system appearance — a forced-appearance probe will render light regardless and mislead you.

Section headings inside the *Settings submenu* are deliberately still plain dimmed items: a greyed
heading is the conventional look inside a menu, and the rows it labels are commands, not data.

**Commands stay plain `NSMenuItem`s**, and this is not a style preference — two things were measured
on a view-backed version of Refresh Now. A hosting view swallows the mouse event, so
`NSMenuItem.action` never fires and the row has to reimplement its own selection and dismissal. And
`keyEquivalent` stops working outright: ⌘Q on a plain item kept working while ⌘R on the view-backed
row did nothing, and `NSMenuDelegate.menuHasKeyEquivalent` — the documented hook for reclaiming it —
is not consulted for status-item menus. A custom command row costs the shortcut, the native
highlight, and AppKit's click routing; that is why Refresh Now shows its age as plain text rather
than as a badge.

## The open dropdown

`rebuild()` refuses to run while the menu is open, and rows are updated in place instead through
`liveRows`. Three reasons rebuilding mid-tracking is wrong: it can delete the parent of an open
Settings submenu, it re-targets a click already in flight (aim at "Refresh Now", hit "Quit
Cashew"), and it destroys highlight and keyboard state. `menuNeedsUpdate` also fires during ⌘R/⌘Q
key-equivalent matching, so this is reachable without the menu ever being clicked.

Live rows close over the window's **`id`** and look it up in current state, never over a
`LimitWindow` value. Capturing the value made a held-open menu keep counting down to a reset the poll
had already replaced, reach "now", and stay pinned there until the menu was reopened.

Measured, not assumed: an open `NSMenu` **does re-layout** when a row's text grows — it does not clip
to its open-time width. A held-open menu was observed resizing 253 → 293 → 640 points mid-tracking
(gaining a weekday at the 24h threshold, then an error footer), growing leftward to keep its right
edge anchored, and landing on exactly the width a from-scratch rebuild produces. So don't reserve or
pad widths. The real limit is *row count*: in-place updates can't add or remove rows, so a window
appearing or disappearing waits for the next open. The menu bar title stays correct meanwhile.

**Height re-lays-out too, but only if the row's frame is changed — AppKit will not work it out.** A
view-backed item is sized by hand once and never again; the width is autoresized to the menu, the
height is not touched. So `HostedRow.update` re-measures on every content swap, and the open menu
follows: a held-open menu was measured going 329 → 314 points tall as the error message dropped from
three lines to two, in step with the row's own 55 → 40. What AppKit will *not* do is notice that the
content inside the host got taller. Left to itself, a row born around "Loading…" clips a later
multi-line error to one line.

The measuring API matters, and the obvious one is wrong. `fittingSize` does not do height-for-width:
for the Keychain-denied message it returns 25pt — one line — whether the row is 200pt or 300pt wide,
and it still returns 25pt with the view in a window after `layoutSubtreeIfNeeded()`, and
`sizingOptions = [.intrinsicContentSize]` reports the same. `NSHostingController.sizeThatFits(in:)`
returns 85pt at 300pt wide and 115pt at 200pt — narrower is taller, which is the proof it is actually
resolving the wrap. That is why the row hosts through a controller rather than a bare
`NSHostingView`.

One trap when checking this by hand: querying menu item names over `osascript` on a **closed** menu
triggers `menuNeedsUpdate` and therefore a rebuild, so it reports fresh text whether or not in-place
refresh works. It only proves something about live updates when paired with evidence the menu is
actually tracking.

## Credentials

Two stores, and choosing between them on *presence* was a real bug: a stale
`~/.claude/.credentials.json` shadowed the live Keychain token forever, every poll 401'd, and the
menu advised opening a Claude Code session — which could never help, because the copy Claude Code
refreshes was the one being ignored. `resolve(file:keychain:)` ranks instead:

1. a bare token (Claude Code never writes that shape, so it's a deliberate human override)
2. whichever `expiresAt` is later
3. the Keychain, matching Claude Code's own precedence

`expiresAt` is **milliseconds** — Claude Code writes `Date.now() + expires_in * 1000`, so a real
value has 13 digits. It is kept as a raw `Double` and never converted to a `Date`; read as seconds it
lands in the year 58,000.

`.absent` and `.accessDenied` are distinct on purpose. Claude Code creates its Keychain item without
`-A`/`-T`, so its ACL trusts only the creating binary and Cashew gets a permission prompt; reporting
a denial as "you've never signed in" is wrong advice on the one path every Keychain-only user takes.
A denial also latches, or a user who clicks Deny would be re-prompted on every poll. The lookup runs
on a serial background queue because that prompt is modal and every `refresh()` caller is the main
thread.

## Claude Code sessions

`HookInstaller` registers `cashew-hook` for ten events — `SessionStart`, `UserPromptSubmit`,
`PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `Notification`, `PermissionRequest`, `Stop`,
`StopFailure`, `SessionEnd`; the helper writes
`~/Library/Application Support/com.vickipetrova.cashew/sessions/<id>.json`; `SessionActivity`
reads the folder. Traps, each measured and each with a test:

- **The hook command must be one command that `exec`s the helper:**
  `[ -x '<path>' ] || exit 0; exec '<path>' <event>`. Run directly, the helper's parent process *is*
  Claude Code (verified on 2.1.273), which is what the liveness check keys on; `exec` replaces the
  shell the guard runs in, so that still holds. A wrapper that doesn't `exec` — `PATH=… cmd`,
  `a && b` — can leave a short-lived shell in between, and every session would look dead a second
  later. `SessionOwner` therefore skips shells, as a backstop. The guard is the other half: see the
  missing-command trap below. It cannot match on the name `claude`: a
  native install's executable is named after its version (`…/claude/versions/2.1.273`), and an npm
  install runs as `node`.
- **`Stop` does not fire on Esc.** An interrupted turn is detected from the transcript, where it is
  a `user` entry starting `[Request interrupted by user`. That entry is frequently **not the last
  line** — `last-prompt`, `ai-title`, `mode`, `permission-mode`, `attachment` and
  `file-history-snapshot` follow it — so `TranscriptTail` takes the last `user`/`assistant` entry. It
  only trusts a transcript written after the session's last hook event, because a new prompt's hook
  fires before the prompt reaches the transcript.
- **Hooks load when a session starts.** Sessions open at first install don't appear until
  restarted; the Settings status says so.
- **A missing hook command is not skipped.** Claude Code runs it anyway, the shell exits 127, and
  the session shows a hook error notice (Claude Code hooks reference) — on every event, for anyone
  who deleted or moved Cashew without turning tracking off. Hence the `[ -x … ] || exit 0` guard:
  leftover hooks exit 0 and print nothing. A test runs the command through `/bin/sh -c` with a
  nonexistent path. Existing installs pick the guarded command up on the next launch, because the
  old entry is stripped by its marker and the new one appended.
- **`Stop` and `PostToolUse` fire only on success.** A turn that ends on an API error fires
  `StopFailure`, and a failed tool call fires `PostToolUseFailure`; without them a session stayed
  "working" or on a tool's label until something else happened. They map exactly like `Stop` and
  `PostToolUse`.
- **`SessionStart` also fires on compaction, mid-turn,** with `source: "compact"`. Resetting the
  session there hid one that was still working, so a compact carries the previous state, label,
  tool and turn start; `startup`, `resume` and `clear` still reset.
- **Only a command containing `/Contents/Helpers/cashew-hook` is Cashew's.** Matching the bare
  name would remove a user's own `my-cashew-hook-script.sh` along with ours.
- **Hooks install only from `/Applications` or `~/Applications`.** Anywhere else — a DMG, a
  translocated copy, Downloads, `build/` — the path goes away and the hooks would point at nothing.
- **A read-only `settings.json` is reported, not overwritten.** The write is atomic, which replaces
  the file through its directory and would succeed over a file the user locked; `apply` checks
  `isWritableFile` first and returns `.writeFailed` without taking a backup.
- **Moving an existing hook to the end would fight other tools.** `HookInstaller.merged` leaves a
  current hook where it is; re-appending it made two tools that both append rewrite the file forever.
- **Transcript tails use the throwing `FileHandle` APIs** (`FileHandle(forReadingFrom:)`,
  `seekToEnd()`, `seek(toOffset:)`, `readToEnd()`). The legacy `seekToEndOfFile()` /
  `readDataToEndOfFile()` raise Objective-C exceptions Swift can't catch, so an I/O error on a
  transcript (a synced volume, a file truncated mid-read) would abort the app instead of reading as
  "not interrupted".
- **The spinning spark draws in a square canvas** (side = the larger of the glyph's width and
  height) at every rotation, including at rest. A canvas sized to the unrotated glyph clips the
  spokes once it turns — measured: ink pixels fell and ink touched the canvas edge at
  11.25°/22.5°/33.75°. `ElapsedAndImageTests.rotationDoesNotClipTheSpark` renders the pixels to hold
  this.

## What Cashew says

`StatusWords` is one phrase book for two surfaces, and both the sharing and the splitting are
load-bearing. `SessionRow` used to build its own status string from the same `session.label`, so the
menu bar and the dropdown could — and did — describe the same session differently.

- **Every pool leads with the plain wording**, and that is not decoration. Element 0 is what the
  menu bar falls back to when a pick doesn't fit, *and* it's the label `HookEvent` writes into the
  session file. `everyLabelTheHookCanWriteHasAPool` holds the two lists together, because they live
  in different modules — the helper links Foundation only, so it can't share the pools themselves.
- **Two caps, for two different reasons.** `maxLength` (18) is the menu bar, shared with every other
  app's item. `rowMaxLength` (30) is the dropdown, and it exists because `NSMenu` sizes itself to
  its *widest* item — one long phrase widens the whole panel, not just its own row.
- **A phrase too long for the menu bar falls back to element 0 rather than being truncated.** So the
  bar can read `Awaiting approval` while the row reads `Tap me — I've got a question.` They agree
  about what is happening; the bar just says it plainly.
- **The pick is keyed on session + turn + moment**, via the same FNV-1a as before (`hashValue` is
  seeded per process, so a word chosen with it would change on every restart, mid-turn). That's what
  holds a phrase still for as long as its moment lasts while letting a long turn visibly move along.
- **`.tool` keeps naming its tool** however long it runs. `lingering` is thinking-only: the row
  already shows `· 12m 30s`, so "still running a command" beats "still".
- **"Done." is dropdown-only.** The dropdown is rebuilt on every open; nothing re-renders the menu
  bar once every session goes quiet, so a finished phrase up there would outstay its 60 seconds with
  no one left to clear it. `Session.justFinished` is derived in `SessionActivity.effectiveState` on
  the genuine-`Stop` branch alone — the interrupted and went-quiet branches return separately, so
  Cashew never congratulates itself for being cancelled.
- **`MenuController.wordWentStale` is not a duplicate of `titleWord.hasPending`.** `hasPending`
  means the hooks announced a change and the hold deferred it. A turn crossing 20s or 10 minutes is
  announced by nothing — it happens on the clock while Claude Code sits silent, which is exactly
  when "been here a while" is worth saying — so there was never anything to defer. Without the
  second check the later moments render only when some unrelated hook happens to fire.

## The app icon

Cashew is `LSUIElement`: no Dock tile, no window. The bundle icon is what Finder, the DMG, the
notification banner, Login Items and the Keychain permission prompt show, so `build.sh` renders one
in two additive tiers: `sips`/`iconutil` turn `assets/icon-1024.png` into an `.icns` always, and
`actool` compiles `assets/Cashew.icon` into `Assets.car` when Xcode is present so macOS 26+ gets
the layered icon. Tier 2 is skipped silently and is never fatal. The `.icns` is byte-identical either
way, so a CLT-only contributor and CI ship the same icon.

**Do not add an inset step to `build.sh`** — `assets/icon-1024.png` is already on Apple's
824-of-1024 grid, and insetting twice makes the icon visibly small. That is the one trap here that
bites someone who isn't touching the icon.

Editing the icon, and the measured traps in `sips`, `actool` and the DMG volume flag:
**[`docs/ICON.md`](docs/ICON.md)**.

## Testing

`swift test --disable-xctest`. Suites live in `Tests/CashewCoreTests/`.

Parsing tests feed **JSON text** through `JSONSerialization`, not Swift dictionary literals — values
have to arrive as the `NSNumber`s the real response produces, or the boolean and integer bridging
paths above go untested.

`NotifierTests` and `SettingsTests` reassign `Settings.defaults` / `Notifier.defaults` to a scratch
`UserDefaults` suite, so they sit under one `@Suite(.serialized)` parent. Two things to know before
editing them:

- **No `deinit`.** swift-testing releases the previous suite instance while constructing the next
  one, so a `deinit` restoring those statics overlaps the next `init` writing them and trips Swift's
  exclusivity checking with a `SIGABRT`. Setup happens in `init`, which wipes the scratch domain.
- **`Notifier.deliver` is injected.** `UNUserNotificationCenter.current()` raises an ObjC exception
  in a process with no app bundle — every `swift test` run — and that's an abort, not a catchable
  error, so one stray call kills the whole run with no attribution.

### Never called from a test

Enforced by a CI grep, and worth understanding rather than working around:

- `Credentials.accessToken()` / `tokenFromFile()` / `tokenFromKeychain()` — read the real Keychain
  item and a live OAuth token, and `#expect` prints compared values into CI logs on failure. Only
  `token(in:)` with synthetic bytes is in scope.
- `Settings.launchAtLogin` — the setter registers a real login item pointing at the test binary.
- `ClaudeProvider.fetch` — real network, real token.
- `Notifier.requestAuthorizationIfNeeded()` / `post` — reach `UNUserNotificationCenter`.
- Constructing `MenuController` or `AppDelegate` — `MenuController` creates a real `NSStatusBar`
  status item in a stored-property initializer, so merely existing needs a GUI session.
- `UsageHistory.default` — writes into the running app's own Application Support folder. Construct it
  with a temp directory instead; that is why the location is a parameter and not a constant.
- `StatuslineFeed.default` — reads the same real folder, and a test that seeded it would be feeding
  the running app. Same fix: construct it with a temp directory.
- `HookInstaller.default` — edits the real `~/.claude/settings.json`. Construct it with a temp
  `claudeDirectory` and a temp helper file. `beforeWrite` is a test seam for the changed-meanwhile
  race, so no test needs the real file to exercise it either.
- `SessionActivity.default` / `SessionFiles.defaultDirectory` — the running app's sessions folder.
- `UpdateCheck.fetch` — real network. `available(data:response:error:currentVersion:)` is the pure part.

### Checking the live app

Reading the menu without screenshots:

```bash
osascript -e 'tell application "System Events" to tell process "Cashew" \
  to get name of every menu item of menu 1 of menu bar item 1 of menu bar 1'
```

For error states that the unit tests can't reach (the real 401 path, a dead network with stale data
on screen), copy `Sources/` to a scratch directory, patch the copy, and build a throwaway bundle from
it.

**A dev bundle doesn't install hooks** — `build/Cashew.app` isn't in an Applications folder, so
session tracking reports "Move Cashew to Applications" — unless you opt in with
`defaults write com.vickipetrova.cashew allowHooksOutsideApplications -bool true`. Doing so
rewrites the real `~/.claude/settings.json` to point at the dev bundle. Before deleting that build,
turn Track Claude Code Sessions off, or unset the default and relaunch the `/Applications` copy so
it points the hooks back at itself. **Never delete or rename the `Claude Code-credentials` Keychain item** — that is Claude Code's
live login, not test data.

## Releasing

Bump `VERSION` in `build.sh`, add the entry to `CHANGELOG.md`, tag `vX.Y.Z`. See
`docs/RELEASING.md` for the manual signing and notarization steps.
