# Claude Code session activity, automatic hooks, and update checks

**Status:** approved design, 2026-09-16 · **Branch:** `feat/session-activity`

## Goal

Bring the useful half of [claude-status-bar](https://github.com/m1ckc3s/claude-status-bar) (MIT,
© 2026 Mick Cesanek) into Headroom, so one menu bar item shows both plan usage and what Claude Code
is doing right now:

1. **Menu bar activity state** — the title shows when any session is working, and when one is
   waiting for permission.
2. **Per-session dropdown rows** — each live session with project, branch, state and elapsed time.
3. **Automatic hook installation** — no snippet to paste.
4. **A daily update check** against GitHub Releases.

This is a port of the *idea*, not the code. claude-status-bar's source is not copied; its README
credits it as the inspiration. Its animations (the Claude spark and the Clawd crab) are Anthropic
trademarks and stay out — the MIT license covers code only.

### Out of scope

- Clicking a row to focus the session's terminal.
- Permission-waiting notifications.
- Launching or quitting Headroom from hooks (Headroom is always running; it has launch-at-login).
- "Thinking words", animation styles, a timer in the menu bar title.
- Homebrew update detection (no cask exists yet).
- Downloading or installing updates (Sparkle-style). The check only links to the release page.

## Rule changes

Two hard rules in `CLAUDE.md` change deliberately, for usability:

- **Rule 5** becomes: *Two network destinations: `api.anthropic.com` for usage, and
  `api.github.com` for a once-a-day update check the user can turn off. No analytics, no
  identifiers.*
- **New rule:** *Headroom edits `~/.claude/settings.json` only to add or remove its own hooks —
  commands that run the bundled `Contents/Helpers/headroom-hook` — and never touches any other key, other hooks, or the
  statusline.*

The `StatuslineFeed` doc comment ("Headroom never edits `~/.claude/settings.json`") is corrected to
match. `README.md` (the "no update checks" line and a new section), `SECURITY.md` (network surface,
files written) and `CHANGELOG.md` are updated in the same change.

## Architecture

```
Claude Code hook ──stdin JSON──▶ headroom-hook <event> ──atomic write──▶ ~/Library/Application Support/
                                                                         com.vickipetrova.headroom/sessions/<id>.json
Headroom: directory watch + fast tick while active ──▶ SessionActivity ──▶ title badge + CLAUDE CODE rows
Headroom launch ──▶ HookInstaller ──▶ ~/.claude/settings.json (own hooks only)
Headroom, ≤ once per 24h ──▶ UpdateCheck ──▶ api.github.com/repos/vickipetrova/headroom/releases/latest
```

### Targets (`Package.swift`)

| Target | Kind | Depends on | Holds |
|---|---|---|---|
| `HeadroomShared` | library | Foundation only | Session file schema, hook event → state mapping, tool labels, the sessions directory location |
| `headroom-hook` | executable | `HeadroomShared` | Top-level code only: read stdin, map, write/delete the session file |
| `HeadroomCore` | library | `HeadroomShared` | Everything else, as today |
| `Headroom` | executable | `HeadroomCore` | Unchanged |

`headroom-hook` must not depend on `HeadroomCore`: it runs on every prompt and tool call and should
not load AppKit/SwiftUI. Still zero third-party dependencies; `swiftLanguageModes: [.v5]` and
`platforms: [.macOS(.v13)]` unchanged. The test target imports both libraries with `@testable`.

## Component 1: `headroom-hook`

Invoked as `[ -x '<helper>' ] || exit 0; exec '<helper>' <event>`, where `<helper>` is
`<app>/Contents/Helpers/headroom-hook` and event is one of:

| Event arg | Claude Code hook | Resulting state |
|---|---|---|
| `start` | SessionStart | `idle`, `started: false` (seeds the file; not shown until real activity). **Except** `source: "compact"` with a previous file: compaction fires mid-turn, so state, label, tool, `started` and turn start carry over |
| `prompt` | UserPromptSubmit | `thinking`, turn start = now |
| `pre` | PreToolUse (`matcher: "*"`) | `tool` with a label from `tool_name` (`Editing`, `Reading`, `Running command`, `Searching`, …, default `Using tool`) |
| `post` | PostToolUse (`matcher: "*"`) | `thinking` |
| `postfail` | PostToolUseFailure (`matcher: "*"`) | `thinking`, as `post` — `PostToolUse` fires only after a tool call succeeds |
| `notify` | Notification | `permission` **only** if `notification_type == "permission_prompt"` or the message mentions permission/approve/allow; otherwise no write |
| `permreq` | PermissionRequest (`matcher: "*"`) | `permission` |
| `stop` | Stop | `idle`, turn start cleared |
| `stopfail` | StopFailure | `idle`, as `stop` — `Stop` does not fire when the turn ends on an API error |
| `end` | SessionEnd | file deleted |

Behaviour:

- Reads stdin with a size cap (1 MB) and a short timeout; malformed JSON is treated as `{}`.
- Session id is sanitized to `[A-Za-z0-9_.-]`, max 64 chars, before use as a filename.
- Written fields: `state`, `label`, `tool` (name only), `cwd`, `transcript` (path), `pid`,
  `started`, `turnStartedAt`, `updatedAt`, `version` (schema version, `1`). Fields missing from an
  event's payload carry over from the previous file.
- **Never** records prompt text, tool input, or tool output.
- Atomic write: temp file in the same directory, then `rename`. Creates the directory if needed.
- Always exits 0, prints nothing — a hook must never disturb a session.

**Parent process.** Verified on Claude Code 2.1.273: when the hook command runs the helper
directly, the helper's parent is Claude Code's own process, stable across events in a session. A shell
wrapper that doesn't `exec` (`PATH=… cmd`, `a && b`) could interpose a short-lived shell, so:

- The installer writes the command as exactly `[ -x '<path>' ] || exit 0; exec '<path>' <event>`.
  `exec` replaces the shell, so the parent is still Claude Code; the guard makes a missing helper
  exit 0 with no output (see Component 2).
- The helper takes its parent unless that parent is a shell (`sh`, `bash`, `zsh`, `dash`, `fish`,
  `ksh`, `tcsh`, `csh`), in which case it walks up (bounded, 5 levels) to the first non-shell.
  Matching on the name `claude` does not work: measured, a native install's executable is named
  after its version (`…/claude/versions/2.1.273`), and an npm install runs as `node`. If no
  non-shell is found it omits `pid`, and the reader falls back to the age cap.

## Component 2: `HookInstaller`

Runs at launch, and when the setting is toggled.

1. If `~/.claude/` does not exist → do nothing (status: Claude Code not found).
2. When enabling: if the helper is not under `/Applications/` or `~/Applications/` → do nothing
   (status: *Move Headroom to Applications to turn this on*). A DMG, a translocated copy, Downloads
   or a build folder would not survive. A translocated path is refused always; any other location is
   allowed only with the developer default `allowHooksOutsideApplications` (off by default).
3. Read `~/.claude/settings.json` (a missing file is `{}`). If it does not parse as a JSON object →
   **do not touch it** (status: *Couldn't read Claude Code's settings.json*).
4. Pure merge, `HookInstaller.merged(settings:helperPath:enabled:) -> [String: Any]`:
   - In each hook event array, remove every hook whose `command` contains
     `/Contents/Helpers/headroom-hook` (not the bare name, so a user's `my-headroom-hook-script.sh`
     survives); drop
     entries left with no hooks; drop event keys left empty **only if we emptied them**.
   - If enabled, append our entry for each of the ten events.
   - Every other key, event and hook is preserved as-is.
5. If the merged object equals the current one → **no write**. A normal launch never touches the
   file.
6. Otherwise: re-read the file and abort if its modification date changed since step 3 (Claude Code
   wrote it meanwhile; retry next launch). If the file exists but is not writable → do not write or
   back up (status: *Couldn't update Claude Code's settings.json*). On the first write ever, copy it to
   `settings.json.bak-headroom` (never overwritten). Write pretty-printed, sorted keys, without
   escaping slashes, to a temp file and rename over the original, preserving its permissions.

Known cost: `JSONSerialization` does not preserve key order, so the first write reorders the user's
file. Content is unchanged, later writes are stable because keys are sorted, and the backup exists.

Parsing uses the `[Any]`-then-filter pattern (never a cast to `[[String: Any]]`), for the same reason
as `limits` in the usage response: one unexpected entry must not discard the array.

**Hooks load at session start** (Claude Code docs). Sessions already open when hooks are first
installed do not appear until restarted; the status says so after a first install.

A missing or non-executable hook command is **not** skipped by Claude Code: the shell exits 127 and
the session shows a hook error notice (hooks reference). The `[ -x … ] || exit 0` guard is what
makes the leftovers of a Headroom deleted without turning the setting off exit 0 with no output. The
README's uninstall section still says to turn it off first, so the entries are removed.

### Setting

**Track Claude Code Sessions** — on by default. Off removes our hooks. Status line beneath it:

| Status | Label |
|---|---|
| installed, sessions seen | `On · 1 session`, `On · 2 sessions` |
| installed, none seen | `On · no active sessions` |
| installed, just now | `On · new Claude Code sessions will appear` |
| before the first apply | `Starting…` |
| off | `Off` |
| off, removal failed | `Off · couldn't remove hooks from settings.json` |
| unparseable settings | `Couldn't read Claude Code's settings.json` |
| changed meanwhile / not writable / write error | `Couldn't update Claude Code's settings.json` |
| not in an Applications folder | `Move Headroom to Applications to turn this on` |
| helper missing from the bundle | `Headroom is incomplete — reinstall it` |
| no `~/.claude` | `Claude Code not found` |

## Component 3: `SessionActivity`

Shaped like `StatuslineFeed`: a struct with an injected directory and a `default` built from
Application Support. Copy strings for the menu live here, not in `MenuController`.

`sessions(now:) -> [Session]` where `Session` is `id`, `state` (`thinking`, `tool(label)`,
`permission`, `idle`), `project`, `branch?`, `turnStartedAt?`, `updatedAt`.

Pipeline:

1. **Parse** each `*.json` defensively (hard rule 3): wrong types or a missing `state` drop that one
   file. JSON booleans are rejected where numbers are expected (`isJSONBoolean`).
2. **Hide unstarted** sessions (`started: false`).
3. **Liveness:** if `pid` is present, `kill(pid, 0)` failing with `ESRCH` → the session is gone;
   the file is deleted (it is Headroom's own directory). The check is injected for tests. Without a
   `pid`: a non-idle state older than 2 hours is treated as `idle`. Any file untouched for 24 hours
   is deleted, with or without a `pid`.
4. **Interrupt detection** for `thinking`/`tool` sessions — `Stop` does not fire on Esc (docs):
   read the last 64 KB of the transcript, parse lines from the end, **skip every entry whose `type`
   is not `user` or `assistant`**, and if the last conversational entry is a `user` message whose
   text starts with `[Request interrupted by user` → `idle`. Verified against real transcripts:
   the marker is frequently followed by `last-prompt`, `ai-title`, `mode`, `permission-mode`,
   `attachment` or `file-history-snapshot` entries, so "last line" is wrong. Cached per transcript
   path by modification date.
5. **Branch:** walk up from `cwd` to a `.git`. A directory → read `.git/HEAD`; a file → follow
   `gitdir:` (worktrees). `ref: refs/heads/x` → `x`; a bare SHA → first 7 chars. No `git` process.
   Cached by `HEAD`'s modification date.
6. **Project name:** `basename(cwd)`; when two live sessions share it, `parent/name`.
7. **Order:** permission, tool, thinking, idle; then most recently updated; then `id`, so full
   ties don't swap places between refreshes.

`aggregate` returns the highest-priority state across sessions, for the title.

### Updates

- A `DispatchSource` file-system object source on the sessions directory (`.write`), debounced
  ~100 ms, calls into `AppDelegate`, which hands sessions to `MenuController`.
- A 0.25 s timer runs **only** while some session is `thinking` or `tool` — it drives the spinning
  spark and re-reads sessions every second — and is invalidated otherwise. A session only awaiting
  permission draws a still dot, so it doesn't run the timer; the directory watch and the 60 s tick
  keep it current. Stopping needs no extra render: handing the sessions to the menu re-renders the
  title at rest. Scheduled in
  `.common` mode, like the existing timers.
- The existing 60 s tick also re-reads sessions, so a killed process disappears even when nothing
  writes.

## Component 4: Menu

**Title.** Usage numbers are untouched; only the spark changes.

- Working: the spark image rotates through frames (Headroom's own glyph). With
  `accessibilityDisplayShouldReduceMotion`, a static alternate image instead.
- Awaiting permission: a dot drawn after the spark — yellow in Alerts-only mode, a monochrome
  template shape in System mode. Takes precedence over working.
- Otherwise: exactly as today.

**Dropdown.** A `CLAUDE CODE` section after the usage rows, before Refresh Now, omitted when there
are no visible sessions.

- One SwiftUI row per session via `NSMenuItem.hosting` (with `title` set for VoiceOver/AppleScript):
  leading `project · branch`, trailing state (`● Awaiting permission`, `Editing · 1m 05s`,
  `Thinking · 12s`, `Idle`).
- At most 6 rows, then a `+N more` row.
- Registered in `liveRows`, closing over the session **id** and looking it up in current state. A
  session that vanished while the menu is open renders `Ended`. New sessions wait for the next open
  (the existing accepted limit on row count).
- `Fmt.elapsed(since:now:)`: `12s`, `1m 05s`, `1h 02m`.

## Component 5: `UpdateCheck`

- `GET https://api.github.com/repos/vickipetrova/headroom/releases/latest` — returns the newest
  non-draft, non-prerelease release, or 404 when none exists (GitHub docs).
- Headers: `Accept: application/vnd.github+json`, `User-Agent: Headroom/<version>` (GitHub rejects
  requests without one). Ephemeral `URLSession`: no cookies, no cache, no identifiers.
- Cadence: first check ~60 s after launch; then at most once per 24 h since the last **attempt**
  (stored in `UserDefaults`); also on wake when due.
- Pure parsing, defensive: `tag_name` (strip a leading `v`) and `html_url`. Versions compare
  numerically component-wise with zero padding, so `0.10.0 > 0.9.0`. A tag with a pre-release
  suffix, an unparseable tag, a non-`https://github.com/` URL, a 404, or any network error → no
  update, silently.
- Menu: when newer, a plain command item `Update Available: v0.2.0…` above Refresh Now that opens
  `html_url`. No download, no install.
- Setting: **Check for Updates Automatically**, on by default.

## Build, CI, release

- `build.sh`: build the `headroom-hook` product universal alongside the app, copy it to
  `Contents/Helpers/headroom-hook`, ad-hoc sign it **before** the app (inside-out, no `--deep`),
  honouring `$HEADROOM_SIGN_ID` the same way.
- CI (`build.yml`): run the existing `lipo` (arm64 + x86_64), `minos 13.0` and no-`OSO` checks on
  the helper too; assert it exists and is executable. Extend the "tests touch nothing they
  shouldn't" grep with `HookInstaller.default`, `SessionActivity.default`, and the `UpdateCheck`
  network call.
- `docs/RELEASING.md`: sign `Contents/Helpers/headroom-hook` with
  `--options runtime --timestamp` before the app — the notary service requires the hardened runtime
  on every executable, helpers included.

## Testing

All `swift test --disable-xctest`; fixtures as JSON **text** through `JSONSerialization`.

- **Hook mapping** (`HeadroomShared`): each event → state/label; `notify` ignores non-permission
  notifications; carry-over of `cwd`/`transcript`; id sanitization.
- **HookInstaller merge:** install into empty/missing settings; preserve unrelated keys and other
  tools' hooks in the same event; replace a stale helper path; removal leaves others intact;
  idempotent (merge of merged == merged, and no write); a non-dictionary entry in a hook array is
  kept, not fatal. Temp-directory tests: backup created once and never overwritten; unparseable file
  untouched; translocated path refused.
- **SessionActivity:** malformed files dropped individually; unstarted hidden; liveness via injected
  check deletes dead files; no-`pid` age cap; interrupt detection on transcript fixtures modelled on
  the real sequences (marker followed by `last-prompt`/`ai-title`/`mode`; marker followed by a new
  `user` prompt → not interrupted); branch from a temp repo (normal, worktree `gitdir:` file,
  detached); project disambiguation; priority order.
- **UpdateCheck:** version comparison table; release JSON parsing including wrong types, missing
  fields, prerelease tags and foreign URLs; the 24 h due rule with an injected clock.
- **Fmt.elapsed** boundaries.

Checked by hand in the live app: install into a real `settings.json` (with a backup of it first),
start a `claude` session, watch thinking → tool → permission → idle, Esc-interrupt, kill the
terminal, toggle the setting off and confirm the hooks are gone.

## Documentation

`CLAUDE.md`: rule changes above, architecture table rows for `HeadroomShared`, `headroom-hook`,
`HookInstaller.swift`, `SessionActivity.swift`, `UpdateCheck.swift`, and the measured traps (guarded
`exec` hook command / parent process; missing command shows a hook error; compaction; interrupt marker not on the last line; hooks load at session start).
`README.md`: session tracking section, update check, uninstall note, acknowledgement of
claude-status-bar. `SECURITY.md`, `CHANGELOG.md` as above.
