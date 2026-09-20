# Roadmap, and other projects in this space

## Roadmap

Deliberately small for v0.1. Not planned by me, but very welcome as contributions — each of these is
[an open issue](https://github.com/vickipetrova/cashew/issues) with the design questions written
out:

- A historical sparkline of the session window — [#2](https://github.com/vickipetrova/cashew/issues/2)
- Graceful mode for non-Pro/Max accounts — [#5](https://github.com/vickipetrova/cashew/issues/5)
- Additional providers — Cursor, Codex, Copilot — behind the existing `UsageProvider` protocol — [#1](https://github.com/vickipetrova/cashew/issues/1)
- Multiple accounts in one menu — [#12](https://github.com/vickipetrova/cashew/issues/12)

The first two are tagged
[good first issue](https://github.com/vickipetrova/cashew/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22);
the rest are
[help wanted](https://github.com/vickipetrova/cashew/issues?q=is%3Aissue+is%3Aopen+label%3A%22help+wanted%22),
meaning they need a design decision agreed in the issue before much code gets written.

Already shipped, and no longer on the list: a configurable menu bar title format and a
model-scoped-only mode, both of which the *Limits shown* setting covers.

Out of scope: cost dashboards, telemetry, anything needing an API key. See
[CONTRIBUTING.md](../CONTRIBUTING.md).

Homebrew is on the list but can't happen yet: Homebrew's
[acceptance policy](https://docs.brew.sh/Package-Acceptance-Policy) asks for 90 forks, 90 watchers
or 225 stars for a project submitted by its own author, and won't consider a repository less than
30 days old. Until then, the DMG is the install.

## Other projects in this space

There are several good ones, and they solve different problems. If Cashew isn't the shape you
want, one of these probably is:

- **[ClaudeBar](https://github.com/tddworks/ClaudeBar)** — the big one. Tracks a dozen assistants
  (Claude, Codex, Gemini, Copilot, and more), themes, Homebrew cask.
- **[Claude Usage Bar](https://github.com/Blimp-Labs/claude-usage-bar)** — richer detail: usage
  history charts, per-model breakdown, extra-usage spend in USD.
- **[ClaudeUsageBar](https://github.com/Artzainnn/claudeusagebar)** — covers claude.ai usage too,
  not just Claude Code. Setup is copying a cookie out of DevTools.
- **[Claude Usage](https://github.com/richhickson/claudecodeusage)** — closest to Cashew in
  spirit: small, native, session and weekly at a glance.
- **[Claude Status Bar](https://github.com/m1ckc3s/claude-status-bar)** — a different question
  entirely: whether Claude Code is *currently* thinking, running a tool, or waiting on you. Pairs
  well with this one, and its repo is the template this one's build script follows.

Cashew's one distinguishing bet is that you shouldn't have to set anything up.

Session tracking was inspired by [claude-status-bar](https://github.com/m1ckc3s/claude-status-bar)
by Mick Cesanek.
