# Changelog

All notable changes to Headroom are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project follows
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **Optional: live numbers from Claude Code's statusline.** Claude Code hands
  `rate_limits.five_hour` and `rate_limits.seven_day` to whatever statusline command you have
  configured, every time it renders — far more often than Headroom polls. One line added to your own
  script drops those in a file, and Headroom overlays them on the polled reading, so session and
  weekly update as you work instead of on a timer. It **supplements** polling rather than replacing
  it: the payload has no per-model breakdown, and an earlier version that used it *instead of*
  polling made the `WEEKLY · OPUS` row blink in and out depending on whether a session was open.
  Headroom never edits `~/.claude/settings.json`; opting in and out is a line you control, and the
  snippet writes only `rate_limits` rather than the cwd, session id, transcript path and cost the
  rest of the payload carries.
  **Settings › Live from Claude Code** says whether it's on, off, or not working because `jq` is
  missing, and when it isn't working offers **Set Up Live Updates…**, a dialog that explains the
  feature and copies the line. The README now has a complete starter script for anyone without a statusline yet.
- **Burn-rate forecasting.** A percentage can't tell you whether you'll make it to the reset — 40% an
  hour into a five-hour window and 40% four hours in read identically. Headroom now keeps a rolling
  history of utilization samples and projects the rate forward. When a limit is on pace to hit 100%
  before it resets, one line appears under it — *"On pace to hit the limit ~Thu 14:00"* — and a
  weekly limit in that state also turns its menu bar percentage yellow, even below the usual 50%
  threshold. Nothing is shown otherwise, deliberately: there is no "you're fine" message to learn to
  ignore. The projection is a straight line over a trailing window (90 minutes for a session limit,
  24 hours for a weekly one), it discards samples from before a reset, and it stays silent rather
  than guessing when the rate is indistinguishable from idle, when there are too few samples, when
  they don't span at least a quarter of the trailing window, or when the whole movement is within the
  endpoint's own rounding — `percent` arrives as an integer, and a single one-point tick over twenty
  minutes is noise, not a rate.
- Samples are stored in `~/Library/Application Support/com.vickipetrova.headroom/history.json` and
  pruned after seven days — the first thing Headroom has ever written to disk. `SECURITY.md`
  documents exactly what is in it, and Uninstall in the README removes it.
- **The last good reading survives a restart.** A launch whose first poll fails — an expired token, no
  network, or the API rate-limiting the request — used to show an error over an empty panel, even
  though perfectly good numbers had been on screen an hour earlier. It now restores what it last saw,
  with the error underneath and *"Showing data from 14:02"* saying how old it is, which is the same
  thing it already did when a poll failed mid-session. Windows that have reset since are dropped
  rather than shown, because their percentage describes a period that has already ended.

### Fixed

- **Headroom now backs off when the API says to.** A rate-limited app kept asking every five minutes
  regardless, discarding the `Retry-After` header along with the rest of the response, and had no way
  back except being noticed and restarted — one instance sat refused for fifteen days. It now honours
  `Retry-After` when the server sends one (in either the seconds or HTTP-date form), doubles the
  interval when it doesn't, caps the wait at an hour, and returns to the normal cadence on the first
  success. The message is no longer *"Usage API returned HTTP 429"* but *"Too many requests — Headroom
  is asking less often until this clears"*, since this is the one error whose fix is to wait.
- **Stale readings are no longer presented as data.** Keeping the last good numbers when a poll fails
  is right for a short outage and wrong for a long one: a reading over a day old, or one for a window
  that has since reset, is now dropped rather than shown, and the panel says only what went wrong.
  The same rule decides what a restart restores, so a reading can't be too stale to keep showing yet
  fresh enough to bring back.
- **"Showing data from …" no longer reports a 15-day-old reading as a time of day.** `Fmt.clock` picks
  its weekday format from `date.timeIntervalSince(now) >= dayThreshold`, which is only ever true
  looking forward; fed a past timestamp it always rendered a bare time. A reading from fifteen days
  earlier displayed as *"Showing data from 4:44 AM"* directly above a correct *"Refresh Now (15d
  ago)"*. Past timestamps now keep the clock time only for today and switch to elapsed time beyond
  that.
- **Message rows no longer clip when their text changes.** A view-backed row was measured once, when
  it was created, so a row built around a short string — "Loading…", or a one-line network error —
  kept that height when a longer message replaced it, and the multi-line Keychain-permission message
  was cut off at one line. Rows created *with* a long message were clipped the same way. Heights are
  now re-measured whenever the content changes, at the width the menu actually gave the row, and the
  open menu grows and shrinks to match.

## [0.1.0] - 2026-08-02

First release.

### Added

- **Menu bar title** — `✻ 42% · 67%`: session (5-hour) and weekly utilization, calm until usage is
  worth noticing and then yellow, then red (see Colors below). Monospaced digits so the title
  doesn't shuffle as numbers change, and you choose which limits appear in it.
- **Dropdown** with each limit window's percentage, reset time, and a live countdown. Countdowns
  refresh in place while the menu is open.
- **Zero-setup authentication.** Reads the OAuth token Claude Code already holds, from
  `~/.claude/.credentials.json` or the login Keychain. Nothing to paste, no cookies, no DevTools.
- **Per-model weekly limits.** The usage endpoint's `limits` array reports model-scoped windows
  that name their own model, so the third row reads "WEEKLY · OPUS" or "WEEKLY · FABLE"
  according to what your plan actually reports. Falls back to the older `five_hour` /
  `seven_day` / `seven_day_opus` keys per field if the array is absent.
- **Show in Menu Bar** — choose which limits appear in the menu bar title. The list is built from
  what the API reports rather than a fixed set, so per-model limits appear by name; the choice is
  stored per limit identifier, survives a limit disappearing and returning, and always keeps at
  least one showing.
- **Colors setting** — *Alerts only* (default) keeps the menu bar and panel calm, colouring only
  once usage passes 50% and again at 80%, so colour carries information instead of being permanently
  on. *System* is fully monochrome and renders the spark as a template image, so the item adapts like
  a built-in menu bar control.
- **Settings submenu** — refresh every 1/5/15 minutes, alert above 50/80/90% or off, colours, launch
  at login. Launch at login delegates to `SMAppService`, so revoking it in System Settings is
  reflected back in the checkmark.
- **Threshold alerts**, at most one per limit window per reset period. Lowering the threshold
  mid-window counts as a new crossing.
- **Honest failure states.** No login found, expired token, and unreachable network each say what
  happened; a failed refresh keeps the last known numbers on screen and timestamps them rather than
  blanking the title.
- **Refresh on wake** from sleep, since timers are unreliable across it.
- `./build.sh` produces a universal (arm64 + x86_64) ad-hoc signed bundle with no Xcode project and
  no third-party dependencies; `--dmg` packages an installer image.
- **An app icon** — two gauge tracks with Anthropic-orange fills, echoing the dropdown's progress
  bars. Headroom has no Dock tile and no window, so this is what Finder, notification banners, Login
  Items and the Keychain prompt show. Built from `assets/icon-1024.png` with `sips` and `iconutil`,
  so the Command Line Tools remain enough to build; when Xcode is present, `assets/Headroom.icon` is
  also compiled with `actool` so macOS 26 and later render the layered icon, including the dark and
  tinted appearances it derives. The `.icns` is identical either way.
- The DMG carries a **volume icon**, so the window you drag from shows Headroom rather than a generic
  white disk.

- **The dropdown is a panel, not a greyed-out menu.** Each limit gets a small-caps heading with its
  reset time, the percentage alongside a countdown, and a slim progress bar in Anthropic orange.
  Previously every informational row was a *disabled* menu item, which macOS draws dimmed — so the
  whole panel read as unavailable. Those rows are now custom views, which macOS renders at full
  strength, while the menu itself still supplies the native material, dismissal and ⌘R/⌘Q.
  **Refresh Now** says how old the numbers are — "Refresh Now (just now)", "Refresh Now (5m ago)" —
  instead of a separate Updated line, so freshness sits next to the thing that acts on it.
- **Tests.** `swift test --disable-xctest` covers endpoint parsing, formatting, alert de-duplication, preference
  validation, credential parsing, and the dropdown's view model. The project builds through SwiftPM (`Package.swift`, no
  third-party dependencies); `build.sh` still produces the universal, ad-hoc-signed `.app`.

### Fixed

Found in a pre-release code review, before first release:

- **Alerts fired on every poll instead of once per window.** The usage endpoint re-stamps
  `resets_at` on every request — three polls twenty seconds apart returned the same reset instant
  with fractional seconds `.516073`, `.880178`, `.202674`. Because the alert marker was keyed on that
  exact timestamp, every poll looked like a fresh period, so anyone over their threshold would have
  been notified twelve times an hour, forever. The period is now quantized to the minute.
- **A leftover credentials file could permanently shadow your live login.** Headroom picked the first
  store that had *anything* in it, so a stale `~/.claude/.credentials.json` — from an older Claude
  Code, a restored backup, or synced dotfiles — hid the Keychain token Claude Code was actively
  refreshing. Every poll failed and the menu advised opening a Claude Code session, which could never
  fix it. Headroom now compares expiry timestamps and uses whichever credential lives longest.
- **"Access denied" was reported as "you've never signed in."** Claude Code's Keychain item only
  trusts the app that created it, so Headroom is prompted for access; declining produced advice that
  couldn't help. It now says what actually happened, and asks once rather than on every poll.
- **The Keychain read could freeze the menu bar.** It ran on the main thread, and it can put a modal
  permission dialog on screen.
- **The bearer token could have followed a redirect to another host.** The connection now refuses
  redirects outright, so "one network destination" is enforced rather than merely documented.
- **A slow refresh could overwrite newer data with older**, timestamped as if it were current.
- **Numbers froze in a dropdown left open.** Percentages and the "Updated" line never changed while
  the menu was on screen, and a countdown would keep running toward a reset time that had already
  been replaced — reaching "now" and staying pinned there until the menu was closed and reopened.
- **A model name reported by the server flowed unbounded into the menu, notifications and stored
  preferences.** It is now trimmed, length-capped, and an empty one no longer renders a heading with empty brackets.
- **The documented release procedure discarded its own notarization.** It rebuilt the app after
  signing and stapling, replacing both with an ad-hoc signature before packaging the DMG. `build.sh`
  gained `--dmg-only` for that step.
- Tagging a release no longer skips the test suite, and a tag that disagrees with the version in
  `build.sh` now fails the release build instead of shipping a mislabeled app.
- A failed ad-hoc signature is no longer swallowed by the build script — on Apple Silicon that
  produced an app that died at launch with the real error discarded.

Found while building the test suite:

- **A single unrecognized entry in the endpoint's `limits` array discarded every other entry.**
  Casting to an array of a concrete element type checks all elements and yields nothing if one
  fails — so one new field shape would have emptied the whole menu instead of dropping one row.
  This was the likeliest way a real endpoint change would have broken the app.
- **A JSON boolean was read as a number.** `{"percent": true}` showed as 1%, and
  `{"resets_at": false}` as 1 January 1970, because booleans bridge to `NSNumber` and satisfy
  `as? Double`.
- **A huge or non-finite percentage crashed the menu bar.** Converting to `Int` for display traps on
  infinity or anything past `Int`'s range; values are now clamped and checked.
- **Raising the alert threshold re-fired an alert already delivered.** Since changing any setting
  re-polls, clicking around the Settings submenu could produce the same alert several times. Lowering
  the threshold still alerts, as intended.
- **A limit window with no reset time was announced once and then never again**, across relaunches,
  instead of once per period.
- **79.6% displayed as "80%" but didn't trigger the 80% alert.** The alert now compares the same
  rounded number the menu bar shows.
- **The clock and the countdown disagreed at exactly 24 hours**, so the dropdown could read
  "Resets 9:00 AM — in 1d 0h" without the weekday that removes the ambiguity.
- **Reset times kept their old format after a system locale change**, because the date formatters
  were built once at launch.

### Known limitations

- Pro and Max plans only. Metered API-key accounts have no session or weekly quota, and Headroom
  says so instead of showing zeroes.

[0.1.0]: https://github.com/vickipetrova/headroom/releases/tag/v0.1.0
