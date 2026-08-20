# Contributing

Thanks for looking. Headroom does one thing — show Claude Code plan usage in the menu bar — and
the goal is to keep it small enough that one person can read the whole thing in an afternoon.

## Building

macOS 13+ and the Xcode Command Line Tools (`xcode-select --install`). Nothing else.

```bash
swift test --disable-xctest   # run the suite first, it takes ~0.05s
./build.sh                    # -> build/Headroom.app
./build.sh --dmg              # also -> build/Headroom.dmg
open build/Headroom.app
```

`swift run` won't work — it makes a bare binary with no `Info.plist`, so there's no menu-bar-only
mode, no login-item identity, and no notifications. Use `./build.sh && open build/Headroom.app`.

Build from the latest `main` so you're not fixing something that already changed.

## What's welcome

Bug fixes. Compatibility fixes across macOS versions and architectures. Better handling when the
usage endpoint drifts. Anything on the [Roadmap](README.md#roadmap) — every item there is an open
issue and genuinely up for grabs.

Two labels, and the difference is real rather than decorative. **`good first issue`** means the shape
is settled and it's a matter of writing the code. **`help wanted`** means there's a design decision to
agree in the issue first — a second provider needs somewhere for two accounts' numbers to go in one
menu bar title, and reading Claude Code's statusline needs a helper process and a write to the user's
`~/.claude/settings.json`. Both are welcome; just don't spend a weekend on either before we've talked
about the shape.

## What won't be merged

- **New dependencies.** AppKit, SwiftUI, Foundation, Security, UserNotifications, ServiceManagement. The
  zero-dependency build is a feature, not an accident — `Package.swift` has no `dependencies:` array
  and shouldn't grow one, for tests either.
- **Anything that logs, caches, or writes the OAuth token.** See below.
- **A second network destination.** No analytics, no telemetry, no update checks, no crash
  reporting. One request, to `api.anthropic.com`.
- **Cost dashboards, spend estimation, billing history.** Other projects do this well and the README
  links them. Headroom keeps a small rolling history of utilization samples for the burn-rate
  forecast — seven days, deleted on uninstall, documented in `SECURITY.md` — and that is as far as
  stored history goes. It exists to answer "will I make it to the reset", not "what have I spent".
- **Anything requiring an API key or costing money to run.**
- **An Xcode project.** `Package.swift` plus `build.sh` is the whole build; an `.xcodeproj` would be
  a second source of truth to keep in sync.

## Ground rules for code

1. **Never print, log, or commit the token.** CI greps for it, but the grep is a backstop, not the
   rule.
2. **Parse defensively.** The usage endpoint is undocumented and community-discovered; it has
   already changed shape once. A field that's missing, null, or the wrong type must drop one row
   and render `–`. It must never crash and never throw.
3. **Keep `MenuController` provider-agnostic.** It renders `[LimitWindow]`. Claude-specific
   strings belong in `ClaudeProvider`.
4. **Match the surrounding style.** Comments explain *why*, not *what*.

`CLAUDE.md` has the architecture map and recipes for exercising each error state without touching
your real credentials — useful whether or not you use Claude Code.

## Testing

`swift test --disable-xctest` must pass, and behaviour changes need a test. The suite is small and
fast; if your change isn't covered by one, that's usually a sign it's worth adding rather than a sign
testing is hard.

Two conventions worth knowing before you add tests:

- **swift-testing, not XCTest.** The Command Line Tools ship `Testing.framework` but *not*
  `XCTest.framework`, so an `import XCTest` compiles for anyone with full Xcode while being
  unrunnable for everyone else. `--disable-xctest` in CI is what keeps that honest.
- **Some APIs are off-limits to tests** — anything reading the real Keychain, registering a login
  item, hitting the network, or constructing `MenuController`. CI greps for them, and `CLAUDE.md`
  explains each.

Then run it. "Builds clean" isn't testing, and neither is "tests pass" for anything you can see.

For anything visual, attach a screenshot of the menu bar title and the open dropdown. Say which
macOS version and which Mac (Apple Silicon or Intel). If you changed parsing, say what you fed it.

Two things are easy to break and easy to check:

- The menu bar title still updates while the dropdown is open (that's why timers are scheduled in
  `.common` run loop mode).
- Countdowns are still right after the Mac wakes from sleep.

## Pull requests

One change per PR. If you're planning something large, open an issue first — I'd rather talk about
the shape before you spend a weekend on it.

`main` is protected: everything lands through a pull request, and CI has to be green before it can
merge. That applies to me too, so if a change of mine looks like it took a detour through a branch,
that's why.

## Commits

[Conventional Commits](https://www.conventionalcommits.org/): `feat`, `fix`, `docs`, `chore`,
`refactor`, `perf`. Branches: `type/kebab-case-description`.

## Conduct

Be decent. Critique code, not people; assume the other person is trying to help. That's the whole
policy, and [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md) is the long form of it, including how to
report a problem privately.

## License

MIT. By contributing you agree your contributions are licensed under it.
