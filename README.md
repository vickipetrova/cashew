Your Claude Code plan usage, in the macOS menu bar — session and weekly percentages, reset times,
and a warning when you're on pace to run out before the window resets.

Zero setup: no cookies, no DevTools, nothing to paste. Cashew reads the OAuth token Claude Code
already has and asks Anthropic the same question `/usage` does.

<!-- HERO GIF: record the menu bar with the dropdown open, save it as assets/cashew.gif,
     and uncomment the line below.
<img src="assets/cashew.gif" alt="Cashew in the menu bar, with the dropdown open" width="480">
-->

```
✻ 42% · 67%
```

## Install

### DMG

*Signed and notarized by Apple.*

1. Download the latest `Cashew-<version>.dmg` from [Releases](../../releases).
2. Open it and drag **Cashew** into Applications.
3. Launch it. It'll ask once for permission to read Claude Code's Keychain item — that's the token.

Homebrew isn't available yet; [RELATED.md](docs/RELATED.md#roadmap) explains why and when.

### Build from source

```bash
git clone https://github.com/vickipetrova/cashew.git
cd cashew
./build.sh
cp -R build/Cashew.app /Applications/
open /Applications/Cashew.app
```

That's the whole toolchain: the Xcode Command Line Tools. No Xcode project, no third-party
dependencies. Tests run with `swift test --disable-xctest`.

> [!NOTE]
> `swift run` won't work, and that's expected — it produces a bare binary with no `Info.plist`, so
> there's no `LSUIElement`, no bundle identity for login items, and no notification registration.
> `./build.sh && open build/Cashew.app` is the way to run it.

## Updating

Cashew asks GitHub once a day whether a newer version exists and adds an **Update Available** item
to the menu, which opens the release page. Download the new DMG and drag it over the old one.

It never downloads or installs anything by itself, and you can turn the check off under
**Settings › Check for Updates**.

## What it shows

- **Session and weekly percentages** in the menu bar, with per-model weekly limits when your plan
  reports them.
- **Live countdowns to each reset**, in the dropdown.
- **A forecast**, when your current burn rate would hit a limit before it resets — and only then.
  It stays silent otherwise, on purpose. [How it works, and its two honest limits](docs/FORECAST.md).
- **What Claude Code is doing**, if you want it: the spark spins while a session is working and
  gains a dot when one wants your permission, and the dropdown lists each live session with its
  project, branch and current step.

Optionally, **live numbers instead of polled ones** — one line in your Claude Code statusline
script makes usage update as you work rather than every few minutes.
[Setup](docs/LIVE-UPDATES.md).

Full list of settings: [SETTINGS.md](docs/SETTINGS.md).

## How it works

Every five minutes (configurable), Cashew sends one request:

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <your Claude Code token>
anthropic-beta: oauth-2025-04-20
```

The token comes from wherever Claude Code keeps it — the macOS login Keychain (generic password,
service `Claude Code-credentials`) or `~/.claude/.credentials.json`. If both exist, Cashew uses
whichever one lives longest, so a leftover file can't shadow your live login. Claude Code refreshes
that token itself while you work, so there is nothing to maintain.

Because this is account-level data rather than session lifecycle, it keeps working when Claude Code
is closed.

> [!NOTE]
> **This endpoint is undocumented and community-discovered.** It is not a public API, and Anthropic
> can change or remove it without notice — it has already grown a second response shape alongside
> the original one. Cashew treats every field as optional: anything missing, null, or unexpected
> renders as `–` rather than crashing. If the numbers ever look wrong, check `/usage` inside Claude
> Code and [open an issue](../../issues) if they disagree.

## Requirements

- **macOS 13+** (Ventura).
- **A Claude Pro or Max plan.** Session and weekly windows are plan quotas; metered API-key accounts
  don't have them, so there's nothing to show — Cashew says so plainly instead of showing zeroes.
- **Claude Code, signed in at least once**, so there's a token to read.

Something looking broken? [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) covers the cases that
usually aren't.

## Uninstall

First, if you use session tracking, turn off **Settings › Claude Code › Track sessions** while
Cashew is still installed — that removes its hooks from `~/.claude/settings.json`. If you turned on
Open at Login, switch that off too. Then:

```bash
rm -rf /Applications/Cashew.app
rm -rf ~/Library/Application\ Support/com.vickipetrova.cashew
defaults delete com.vickipetrova.cashew
rm -f ~/.claude/settings.json.bak-cashew
```

That is everything: the app; the usage history and session files; your preferences; and the one-time
backup of your Claude Code settings. No caches, no logs, no other files.

## Security

Cashew reads your OAuth token, holds it in memory for one request, and sends it to exactly one
place: `api.anthropic.com`. It also asks GitHub once a day whether a newer Cashew exists (turn it
off under Settings). Neither request follows a redirect. No telemetry, no analytics, no identifiers.

With session tracking on it also reads the tail of your Claude Code transcripts — to tell an
interrupted turn from a finished one — and keeps nothing from them but a yes-or-no.

[SECURITY.md](SECURITY.md) is the complete account: every file written, every preference stored,
and everything read.

## Contributing

Deliberately small. [CONTRIBUTING.md](CONTRIBUTING.md) has the scope, and
[RELATED.md](docs/RELATED.md) the roadmap and the other projects in this space — several are better
fits for things Cashew won't do.

## Trademark / Not affiliated

This is an unofficial, open-source side project. **It is not affiliated with, endorsed by, or
sponsored by Anthropic.** "Claude" and the Claude spark are trademarks of Anthropic, used here
nominatively. The MIT license below covers this source code only and conveys no rights to
Anthropic's trademarks or brand.

## License

MIT © Victoria Petrova. See [LICENSE](LICENSE).
