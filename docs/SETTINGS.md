# Settings

Everything lives in the dropdown under **Settings**, grouped into three sections.

| Settings ▸ | Setting | Options | Default |
|---|---|---|---|
| **Menu Bar** | Limits shown | any combination of the limits your plan reports, or none | Session + Weekly |
| | Status words | on / off | on |
| | Animation | Spark spin / Spark pulse / Gauge sweep / Orbiting dot / Meter bars / Cashew | Spark spin |
| | Color | Only when usage is high / Never | Only when usage is high |
| **Alerts & Refresh** | Notify when usage passes | Never / 50% / 80% / 90% | 80% |
| | Check usage every | 1 / 5 / 15 minutes | 5 minutes |
| **Claude Code** | Track sessions | on / off, with a status line under it | on |
| | Live updates | status, and setup when it's off — see [LIVE-UPDATES.md](LIVE-UPDATES.md) | off |
| *(top level)* | Open at Login | on / off | off |
| | Check for Updates | on / off | on |

On/off settings are switches, and flipping one leaves the menu open — you can change two or three in
a visit. Picking from a list (an animation, a colour, a threshold) closes the menu, the way choosing
from any macOS menu does.

## Limits shown

Picks which numbers appear in the title. The list is built from whatever the API currently reports,
so a per-model limit shows up by name once your plan has one. Choices are stored against each
limit's identifier rather than its name, so a limit that disappears for a while comes back selected
rather than silently reset.

Unticking all of them is allowed: the menu bar then shows the cashew on its own, plus whatever the
status words are saying.

## Color

Decides how much colour the menu bar and the panel use.

*Only when usage is high* keeps the spark orange and everything else in the ordinary label colour
until usage is worth noticing, then turns yellow at 50% and red at 80% — so colour means "look at
this" rather than being permanently on.

*Never* is fully monochrome: the thresholds stop applying entirely and the spark becomes a template
image, so the whole item adapts like a built-in menu bar control.

## Alerts

Alerts fire at most once per window per reset period, so sitting at 85% doesn't produce an alert on
every poll. Lowering the threshold mid-window counts as a new crossing and will alert again.

macOS asks for notification permission the first time Cashew runs with alerts switched on. If you
decline — or later switch Cashew off in System Settings › Notifications — the menu says
*"Alerts blocked — open Notification settings"* rather than silently never alerting you.

## Track sessions

Cashew shows what Claude Code is doing: the spark spins while a session is working and gains a dot
when one is waiting for your permission, and the dropdown lists each live session with its project,
branch, current step and how long the turn has run.

To do that, Cashew adds hooks for ten Claude Code events to `~/.claude/settings.json` the first time
it runs from `/Applications` (or `~/Applications`): `SessionStart`, `UserPromptSubmit`,
`PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `Notification`, `PermissionRequest`, `Stop`,
`StopFailure` and `SessionEnd`.

It changes nothing else in that file, keeps a one-time backup at `~/.claude/settings.json.bak-cashew`,
and records only each session's state, folder, transcript path and tool *name* — never your prompts,
tool input or output. [SECURITY.md](../SECURITY.md) has the full account, including the transcript
read this feature depends on.

Sessions already open when the hooks are added appear once they're restarted.

Turning it off removes the hooks. **Turn it off before deleting Cashew.** If you forget, each
leftover hook checks that Cashew's helper is still there and exits quietly when it isn't, so your
sessions are unaffected — but the entries stay in `settings.json` until you remove them
(reinstalling Cashew and turning tracking off does it for you).
