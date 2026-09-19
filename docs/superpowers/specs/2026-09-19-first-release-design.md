# Preparing Cashew for its first release — design

**Date:** 2026-09-19
**Target:** v0.1.0, the first public release
**Status:** awaiting review

## The question this answers

Cashew is feature-complete and tested but has never been released. There are no tags and no
GitHub releases. This spec covers what has to be true before `git tag v0.1.0`, and what the
install story looks like on the other side.

Five decisions were settled before writing this, and the rest of the document follows from them:

| Decision | Choice | Why |
|---|---|---|
| Distribution | Signed + notarized DMG on GitHub Releases | The Mac App Store is structurally closed (below). Homebrew is not available yet (below). |
| Homebrew | Deferred, not abandoned | Repo does not meet the acceptance bar and cannot for at least 30 days. |
| Updating | Notify-only, already built | Hard rules 2 and 5 both point here; the reference project reached the same answer. |
| DMG filename | `Cashew-<version>.dmg` | A cask's `url` must contain the version verbatim or bump tooling cannot work. |
| README | ~120 lines, details in `docs/` | Matches the reference project's shape; the current 338 lines bury the install. |

## Why the Mac App Store is not an option

Not a preference — a structural exclusion, worth recording so it is not re-litigated.

App Store Review Guideline **2.4.5(i)** requires Mac App Store apps to be "appropriately
sandboxed." Guideline **2.5.2** adds that apps "may not read or write data outside the designated
container area."

Every load-bearing thing Cashew does lives outside that container:

- reads Claude Code's Keychain item (`Claude Code-credentials`) — another app's item, with no
  shared access group
- reads `~/.claude/.credentials.json`
- writes its hook entries into `~/.claude/settings.json`
- reads session transcripts at paths Claude Code chooses

There is no entitlement that buys an exception, because the app is *defined* by reading another
application's credentials. A notarized DMG is therefore not a lesser option; it is the only one,
and it is what comparable menu bar utilities ship.

## Why Homebrew is deferred

Homebrew's [Package Acceptance Policy](https://docs.brew.sh/Package-Acceptance-Policy) sets a
higher bar for an author submitting their own project:

> * at least 30 forks, 30 watchers or 75 stars.
> * at least 90 forks, 90 watchers or 225 stars for a self-submission by the repository owner.
>
> A code repository less than 30 days old is normally not eligible.

A first release meets neither the count nor the age. Two further findings shape the plan:

**Homebrew confers no Gatekeeper relief.** The `--no-quarantine` flag and the `quarantine false`
stanza have both been removed — absent from the current Manpage, the Cask Cookbook, and
`cask/dsl.rb`. `cask/download.rb` applies quarantine unconditionally:

```ruby
downloaded_path = cached_download
quarantine(downloaded_path)
```

So shipping unsigned via a personal tap would buy a tidy install command and nothing else; users
would still hit Gatekeeper. Notarization is required regardless of channel, which makes it the
first priority rather than a Homebrew prerequisite to defer.

**homebrew/cask hard-requires notarization.** `brew audit` runs `gktool scan` per app artifact and
fails with "The homebrew/cask tap requires all casks to be signed and notarized by Apple." There is
no waiver, and casks that later fail are deprecated and removed.

**Consequence for this release:** notarize from v0.1.0, name the DMG so a future cask can
interpolate the version, and revisit Homebrew once the repo qualifies. The cask token `cashew` is
currently unregistered; `headroom` is already taken by an unrelated cask, so the project name must
not drift that way.

## Why updating stays notify-only

`UpdateCheck.swift` already asks GitHub once a day whether a newer release exists and adds an
`Update Available: v0.2.0…` item that opens the release page. It is wired through
`AppDelegate.startUpdateChecks()` and can be switched off.

Going further would mean either adding Sparkle — a third-party dependency, which hard rule 2
forbids — or downloading and replacing the app bundle in-process, which adds a third network
destination against hard rule 5. For an app that reads the user's Claude credentials, "it replaces
its own binary" is a materially larger promise than "it tells you there's a new version."

A future refinement worth recording but explicitly **out of scope for v0.1.0**: detect which
channel the app was installed through and show a different affordance for each (a copyable
`brew upgrade` line for cask installs, the release page for DMG installs), suppressing the notice
for cask users until the cask has actually been bumped. This only becomes relevant once a cask
exists.

## Work items

### 1. SECURITY.md corrections

The document has drifted from the code. Two claims are wrong and two disclosures are missing. Every
finding below was verified against source, and the file:line references are the evidence.

**P0 — "both written after a successful poll and only after a successful poll" is false.**

`publishMergingLiveReadings` writes `history.json` and `snapshot.json`
(`AppDelegate.swift:125-132`) and is called from two places: the poll-success branch, and the
60-second tick (`AppDelegate.swift:44-51`) whenever `!polled.isEmpty || statusline.read() != nil`.
So both files are rewritten roughly once a minute, and a statusline-feed user who has never had a
successful poll still gets them written.

Replace with wording that covers both triggers, naming the statusline feed as a source that can
cause a write on its own.

**P0 — "your four preferences" undercounts by seven.**

`Settings.swift:37-49` defines eleven keys. Documented: `refreshMinutes`, `notifyThreshold`,
`colorMode`, `titleLimitIDs`. Undocumented: `trackSessions`, `menuBarAnimation`, `showStatusWords`,
`checkForUpdates`, `allowHooksOutsideApplications`, `lastUpdateCheck`, `knownRelease`.

None hold usage data, so the document's conclusion survives — but "that is the whole extent of it"
reads as an exhaustive inventory and must either become one or stop claiming to be one.
`lastUpdateCheck` is a timestamp of app activity and `knownRelease` stores `{tag_name, html_url}`;
both should be named. `allowHooksOutsideApplications` should be identified as a developer switch
with no menu item.

**P1 — Cashew reads transcript contents, and the document does not say so.**

`TranscriptTail.swift:32-43` reads the last 64 KB of a tracked session's transcript;
`endsInInterrupt` (`:45-55`) parses text out of `message.content` on the last user/assistant entry
to test for the `[Request interrupted by user` prefix. Nothing is persisted — only a `Bool` is
cached in memory. `GitBranch.swift:11-19` similarly reads `.git/HEAD`.

The current "What it reads" section lists only the token. A reader would reasonably conclude Cashew
never opens their conversations. The code is clean; the disclosure is missing, and this is the gap
most likely to be found by a stranger and read as concealment. Add both reads, and state plainly
what is and is not retained.

**P1 — session file naming and tool names.**

Session files are named by the Claude Code `session_id`, sanitized (`SessionRecord.swift:115-125`).
The `tool` field holds the raw tool name capped at 64 characters, so an MCP tool name
(`mcp__<server>__<action>`) reaches disk — still a name and not input, but it discloses which MCP
servers the user runs. Both are worth stating.

**P2 — accuracy polish.**

- The update-check session has no redirect delegate (`UpdateCheck.swift:90-97`); see item 2.
- Two `NSWorkspace.open` calls (`MenuController.swift:666` release page, `:789-791`
  `x-apple.systempreferences:`) deserve their own heading, separate from network destinations. The
  release URL is host-validated at `UpdateCheck.swift:61-62` and re-validated on read-back from
  UserDefaults (`Settings.swift:175`), so a hand-edited plist cannot redirect it — worth saying.
- `~/.claude/settings.json` is rewritten `.prettyPrinted, .sortedKeys` on first enable
  (`HookInstaller.swift:91-92`), so key order and formatting change even though no other key's
  value does.
- The usage session does not explicitly nil `httpCookieStorage` (`UsageAPI.swift:171-174`) while
  the update session does. `.ephemeral` already gives an in-memory-only jar, so nothing is
  persisted either way; set it on both for symmetry.

**Verified accurate, and not to be weakened while editing:** exactly two network destinations; the
usage session refuses every redirect (`RefuseRedirects`, `UsageAPI.swift:158-165`); the token is
read fresh per request and never cached, logged or interpolated anywhere but the `Authorization`
header; no `print`/`NSLog`/`os_log`/`debugPrint` exists anywhere in `Sources/`;
`UsageError.errorDescription` returns fixed strings so a network error cannot leak the token; the
Keychain read is in-process `SecItemCopyMatching` with no subprocess; session records contain no
prompt text, `tool_input` or `tool_response` — `HookEvent` reads `message` only for a
`.contains("permission")` test and never stores it; `HookInstaller` touches only its own entries;
Cashew never writes `statusline.json`.

### 2. Redirect guard on the update check

Give the update-check session the same `RefuseRedirects` delegate the usage session uses, so
SECURITY.md can state one rule rather than an asymmetry. `RefuseRedirects` moves somewhere both
files can reach it.

Currently a GitHub 301 — a repo rename or transfer — would re-send the `User-Agent: Cashew/<version>`
header to the redirect target. No token is at risk; the value is consistency and a document that
does not need a caveat.

A test asserts the delegate refuses. It must not perform real network I/O: `UpdateCheck.fetch` is
on the never-called-from-a-test list and stays there.

### 3. README restructure

338 lines → roughly 120. Demo video above the first heading, no badge row, no `# Cashew` H1 — the
repository name serves as the title, which is the shape the reference project converged on.

Section order: *(hero + video)* · Install · Updating · What it shows · How it works · Requirements ·
Uninstall · Security · Trademark · License.

Moving out, not deleted:

| New file | Content moved |
|---|---|
| `docs/LIVE-UPDATES.md` | The statusline opt-in: both snippets, the status table, the supplement-not-replacement rationale |
| `docs/FORECAST.md` | "Why not the built-in menu bar?" — the rate argument and the two honest limits |
| `docs/SETTINGS.md` | The full settings table and the per-setting prose |
| `docs/TROUBLESHOOTING.md` | Keychain prompt on rebuild, hooks needing a session restart, the dev-bundle "Move Cashew to Applications" message, `CLAUDE_CONFIG_DIR` |
| `docs/RELATED.md` | Other projects in this space, and the Roadmap |

**Constraint, and it reaches shipping code rather than only the tests.**
`StatuslineFeed.setupSnippet` embeds a hardcoded URL (`StatuslineFeed.swift:129`):

```
# https://github.com/vickipetrova/cashew#live-usage-from-claude-code
```

That line is *pasted into the user's own statusline script* by Settings › Copy Setup Snippet, and
stays in their file indefinitely. Moving the section to `docs/LIVE-UPDATES.md` invalidates the
anchor in a file Cashew can never revisit.

Two tests hold this together (`StatuslineFeedTests.swift:191`, `:201`): one asserts the README
quotes `setupCommand` verbatim, the other asserts the snippet's anchor matches a heading that
exists — `#expect(text.contains("\n## Live usage from Claude Code\n"))`.

So the move requires, in one change: the snippet's URL repointed to
`https://github.com/vickipetrova/cashew/blob/main/docs/LIVE-UPDATES.md`, both tests repointed at
that file, and the heading present there. Doing this before v0.1.0 costs nothing; doing it after
means every existing user carries a stale link. This is the strongest argument for fixing the
documentation layout *before* the first release rather than after.

The install section states *Signed and notarized by Apple* and links to the Releases page rather
than a direct asset URL, since the versioned filename makes a permanent asset link impossible and
the releases page shows the changelog anyway.

### 4. Build and release plumbing

- `build.sh` emits `build/Cashew-$VERSION.dmg` — `DMG="build/$APP_NAME.dmg"` at `build.sh:226`, and
  the intermediate `RW="build/$APP_NAME-rw.dmg"` at `:249`. The mounted volume name and the
  `Cashew.app` inside are unchanged; only the image filename carries the version, so the DMG's
  appearance when opened is identical.
- `.github/workflows/release.yml` attaches the new filename. The existing tag-matches-`VERSION`
  guard already prevents the mismatch that would otherwise produce a wrongly-named asset.
- `docs/RELEASING.md` updated for the new name throughout, including the `spctl` and `stapler`
  verification lines.

`docs/RELEASING.md` is otherwise correct as written: the inside-out signing order, the requirement
to notarize the app and the DMG separately, and the `--dmg-only` trap are all right and stay.

### 5. Repository hygiene

`CASHEW_PLAN.md` is tracked in git despite being listed in `.gitignore` — gitignore does not untrack
an already-committed file. It is an internal planning document in a public repository. Remove with
`git rm --cached`, same for `assets/.DS_Store`.

Verify no other ignored-but-tracked file exists before tagging.

## Out of scope

Recorded so they are not silently dropped:

- The Homebrew cask and tap — revisit when the repo qualifies
- Install-channel detection in the update notice — only meaningful once a cask exists
- In-app download and install of updates — blocked by hard rules 2 and 5
- Everything in the README's Roadmap section

## Testing

`swift test --disable-xctest` after each work item, not only at the end. The README/`docs` split is
the item most likely to break it, via the statusline snippet test.

The security corrections are documentation and are verified by re-reading the cited source, not by
tests. The redirect guard gets a test that exercises the delegate without network I/O.

Before tagging: build, install to `/Applications`, confirm the menu bar renders, confirm Settings
shows the hook status as installed, and confirm `spctl -a -t open --context context:primary-signature -v`
accepts the signed DMG.

## Sequencing

One branch, `chore/release-prep`, in the order above: security corrections, then the redirect guard,
then the README split, then build plumbing, then hygiene. `main` is protected, so this merges by PR
with the `build` check green.

Tagging `v0.1.0` is a separate, later step and is not part of this branch.
