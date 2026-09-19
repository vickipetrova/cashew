# Cashew — Build Plan

Plan for Claude Code. Execute phases in order. Stop and ask before anything marked **[ASK]**.

## What we're building

**Cashew** — a tiny macOS menu bar app showing Claude Code plan usage at a glance:

```
✻ 42% · 67%
```

Session (5-hour window) % · Weekly (7-day) %. Click for reset times, countdowns, and Opus weekly if present. Open source (MIT), zero dependencies, built with `swiftc` — no Xcode project.

**Positioning (one line for the README):** zero-setup — reads Claude Code's own OAuth token automatically (file or Keychain), polls the same endpoint behind `/usage`. No cookies, no DevTools, no pasting anything.

## Reference materials

1. **Pattern reference:** https://github.com/m1ckc3s/claude-status-bar — mirror its repo structure, build.sh approach (plain `swiftc` → .app bundle), README tone, and trademark disclaimer. Clone it and study README.md, build.sh, and repo layout before writing anything.
2. **Prototype:** the user will provide a `claude-usage-bar.zip` containing a working single-file prototype (`Sources/main.swift`, `build.sh`, `README.md`). Use it as the starting point. You may restructure, but preserve its behavior and defensive parsing.

## Product spec

### Data source
- Endpoint: `GET https://api.anthropic.com/api/oauth/usage`
- Headers: `Authorization: Bearer <token>`, `anthropic-beta: oauth-2025-04-20`, `Accept: application/json`
- Token discovery, in order:
  1. `~/.claude/.credentials.json` → `claudeAiOauth.accessToken`
  2. macOS login Keychain, generic password, service `"Claude Code-credentials"` (contains the same JSON blob, or a raw token)
- Response shape (defensive — this endpoint is undocumented and may drift):
  `{ "five_hour": { "utilization": <0-100>, "resets_at": <ISO8601> }, "seven_day": { ... }, "seven_day_opus": { ... optional } }`
- Parse ISO8601 with and without fractional seconds. Accept `utilization` as Double or Int. Missing windows are fine — render "–".

### Menu bar
- Title: `✻ S% · W%` — spark in Anthropic orange `#d97757`, percentages in monospaced digits, color-coded: green <50, yellow 50–79, red ≥80.
- Loading: `✻ …`  Error: `✻ !`
- No dock icon (`LSUIElement` + `.accessory` activation policy).

### Dropdown menu
- SESSION (5-hour window): `X% used` / `Resets HH:mm — in 2h 13m`
- THIS WEEK (all models): same format; show weekday (`Tue 09:00`) when reset >24h away
- THIS WEEK (Opus): only if present in response
- `Updated HH:mm` (last successful fetch)
- Separator → `Refresh Now (⌘R)` → `Settings ▸` → `Quit (⌘Q)`

### Behavior
- Poll every 5 minutes (configurable in Settings: 1/5/15 min). Re-render countdowns every 60s between polls.
- On 401: keep last known data, title stays but menu shows "Token expired — open a Claude Code session to refresh it."
- No credentials found: menu shows "No Claude Code login found. Open Claude Code once to sign in."
- Network failure: keep last data, show stale time.

### v0.1 features (beyond prototype)
- **Notifications:** UserNotifications alert when session or weekly crosses a threshold (default 80%, off/50/80/90 in Settings). Fire once per window per crossing — track last-notified reset timestamp to avoid repeats.
- **Launch at login:** `SMAppService.mainApp` toggle in Settings.
- **Settings:** simple NSMenu submenu (refresh interval, threshold, launch at login) persisted in UserDefaults. No settings window in v0.1.

### Non-goals (v0.1)
No multi-account, no historical charts, no other providers, no cost estimation, no statusline hooks. List these under Roadmap in the README instead — they're contributor entry points.

## Architecture

Keep the no-Xcode-project, `swiftc`-built ethos, but split for contributability:

```
Sources/
  main.swift            # app entry, AppDelegate, timers
  MenuController.swift  # status item, menu building, rendering
  UsageAPI.swift        # endpoint client + response models
                        # Define a minimal `UsageProvider` protocol (name, fetch() -> [LimitWindow])
                        # with ClaudeProvider as the only implementation in v0.1. Keep models
                        # provider-agnostic so Cursor/Codex/ChatGPT providers can be added later
                        # without touching MenuController. Do NOT build multi-provider UI now.
  Credentials.swift     # file + Keychain token discovery
  Format.swift          # percentages, countdowns, colors
  Settings.swift        # UserDefaults-backed preferences
  Notifier.swift        # threshold notifications
```

`build.sh` compiles `Sources/*.swift` into `build/Cashew.app` with Info.plist (LSUIElement, bundle id — **[ASK]** the user for their bundle id prefix), ad-hoc codesign. Add `--dmg` flag mirroring the reference repo.

## Repo scaffolding (open source hygiene)

Create all of:

- **README.md** — hero GIF placeholder at top, one-line pitch, "How it works" (endpoint + token discovery, honest note that the endpoint is undocumented/community-discovered), Install (DMG + build-from-source), Requirements (macOS 13+, Pro/Max plan — API-key accounts have no quota to show), Settings, Comparison one-liner vs existing tools (link them — claudecodeusage, ClaudeBar, claude-bar — be generous, not competitive), Roadmap, Uninstall, Trademark disclaimer copied in spirit from the reference repo ("unofficial, not affiliated with Anthropic; Claude is a trademark of Anthropic"), License.
- **LICENSE** — MIT, user's name. **[ASK]** for the copyright name to use.
- **CLAUDE.md** — for future Claude Code sessions: build/run commands (`./build.sh && open build/Cashew.app`), architecture map (one line per source file), hard rules (zero third-party dependencies; never log or commit tokens; all parsing of the usage endpoint must be defensive — it is undocumented; ad-hoc signing only in build.sh), how to test error states (rename `~/.claude/.credentials.json` temporarily; use a bogus token for 401), release process summary.
- **CONTRIBUTING.md** — how to build, code style (match existing, no deps), PR expectations (small, one change), where good first issues live.
- **CHANGELOG.md** — Keep a Changelog format, seed `0.1.0`.
- **.gitignore** — `build/`, `.DS_Store`, `*.dmg`.
- **.github/ISSUE_TEMPLATE/** — `bug_report.md` (include macOS version, Claude Code version, plan type), `feature_request.md`.
- **.github/pull_request_template.md** — checklist: builds with ./build.sh, no new dependencies, no token logging.
- **.github/workflows/build.yml** — CI on PR/push: `macos-latest` runner, run `./build.sh`, verify the binary exists. (No signing in CI.)
- **.github/workflows/release.yml** — on tag `v*`: build, package DMG, attach to a draft GitHub Release. Leave notarization as a documented manual step (see below).
- **SECURITY.md** — short: what the app reads (token), where it sends it (api.anthropic.com only), no telemetry, how to report issues.

Skip: code of conduct file (fold one sentence into CONTRIBUTING), FUNDING.yml (add later if wanted).

## Execution phases

**Phase 0 — Study.** Clone the reference repo. Read its README, build.sh, layout. Unzip the prototype. Summarize both back in ≤10 lines before writing code.

**Phase 1 — Scaffold.** Create the repo structure above with stub docs. Init git, first commit.

**Phase 2 — Core app.** Port prototype into the module layout. `./build.sh` must succeed. Run it; verify menu bar renders with live data.

**Phase 3 — Features.** Settings, notifications, launch at login. Verify each: change refresh interval takes effect; force a threshold crossing by setting threshold below current usage; toggle launch-at-login and check System Settings → Login Items.

**Phase 4 — Error-state QA.** Temporarily rename `~/.claude/.credentials.json` (restore after) → verify Keychain fallback or friendly error. Point at an invalid token → verify 401 message. Kill network → verify stale-data behavior. Restore everything.

**Phase 5 — Docs pass.** Fill README fully, write CLAUDE.md/CONTRIBUTING/SECURITY for real, seed CHANGELOG. Add 4–6 GitHub Issues labeled `good first issue` from the Roadmap (multi-account, historical sparkline, statusline-stdin data source, configurable title format, Opus-only mode, non-Pro/Max graceful mode, additional providers — Cursor / Codex / ChatGPT / Copilot — behind the UsageProvider protocol).

**Phase 6 — Release prep.** Verify both workflows pass. Tag `v0.1.0` **[ASK]** before tagging.

## Manual steps for the user (not Claude Code)

- Create the GitHub repo `cashew`, set description "Claude Code usage in your macOS menu bar — session %, weekly %, reset times", add topics `claude-code`, `claude`, `macos`, `menubar`, `swift`.
- Record the hero GIF (menu bar + dropdown open) and drop it into `assets/`.
- Notarization: requires the user's Apple Developer credentials — document the `notarytool` commands in a `docs/RELEASING.md` but never ask for or handle the credentials. Ad-hoc build works for build-from-source users meanwhile.

## Guardrails

- Never print, log, or commit the OAuth token or credentials file contents. Not in debug output, not in error messages, not in CI.
- Exactly one network destination: `api.anthropic.com`. No analytics, no update checks in v0.1.
- Zero third-party dependencies. AppKit + Foundation + UserNotifications + ServiceManagement only.
- Any change to endpoint parsing must degrade gracefully to "–", never crash.
