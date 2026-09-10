# Usage limits — design

**Status:** design agreed on the three placement decisions. Ready for review, then planning.

**Phase:** v0.10.0

**Mockup:** every surface below was drawn at 1:1 in Clyde's own palette before this was written — https://claude.ai/code/artifact/5d562f92-6507-419a-802f-aa55193903fb

## What this is

Claude Code meters a Pro or Max subscription in two rolling windows: a five-hour session window and a seven-day week. Both are visible in the terminal only by running `/usage`, and the moment they matter most — the session window closing in the middle of a task — is the moment nobody is looking at them. Clyde already sits on the screen all day watching those sessions. This adds the two windows to what it watches: how much of each is used, and when each resets.

## Where the numbers come from

Claude Code passes a `rate_limits` object to whatever script is configured as `statusLine` in `~/.claude/settings.json`: `five_hour` and `seven_day`, each with `used_percentage` (0–100) and `resets_at` (Unix seconds). That is the whole data set — four numbers — and it is the only official, documented, token-free route. The alternatives were investigated and rejected: the OAuth endpoint behind `/usage` answered two probes with a 429 and a 44-minute `retry-after`, shares its bucket with Claude Code itself, and depends on a token only Claude Code can refresh; a one-token probe call spends the limit to measure it.

The consequences of that source shape everything below:

- **Pro and Max only.** On an API key, Bedrock, Vertex or Foundry the object never appears, and neither does any of this UI.
- **Only after the first API response in a session.** A machine with no Claude Code session open produces no new numbers. The last snapshot stands until one does.
- **Account-wide, not per session.** Every session's status line reports the same two windows; last writer wins and that is correct.
- **Event-driven.** The status line re-runs after each API response and on a 300 ms debounce, never on a timer unless `refreshInterval` is set, and a timer re-run would only repeat the last values. Freshness is therefore a property of the data and the UI must carry it.

## Installing the status line

Clyde installs a wrapper script the same way it installs the hook: `~/.claude/hooks/clyde-statusline.sh`, registered as `statusLine.command` in `settings.json`, versioned with a `# clyde-statusline-version: N` line and reinstalled when the bundled copy is newer. The installer lives beside `HookInstaller` and follows its rules: refuse to touch an unparseable `settings.json`, write atomically, record the self-write time so the health check does not flag its own edit.

**The wrapper never replaces a status line the user already has.** `statusLine` is a single slot. If a command is already configured, the installer stores it verbatim in `~/.clyde/usage/passthrough` and the wrapper, after writing its snapshot, pipes the same stdin into that command and prints whatever it prints. Uninstalling restores the stored command. If the stored command and the configured command ever disagree — the user edited settings by hand after install — the health check reports it the way a missing hook is reported today, and reinstalling adopts the user's new command.

**When there is no user status line, the wrapper prints one line:** the model name, then `5h 42% · 7d 18%` when the object is present, nothing more. This is the one visible side effect of the feature in the terminal. A configured status line also makes Claude Code stop showing most of the footer's keyboard hints, so this is not invisible the way the hook is. That is why the feature is **opt-in**: a toggle in Settings, off by default, with a one-time advisory in the panel — the same advisory chip and detail card the hook health issues use — saying that Clyde can show Claude's limits and what turning it on changes in the terminal. The toggle explains the same thing in a sentence.

**Snapshot.** The wrapper buffers stdin and writes it whole, atomically (`mktemp` + `mv`), to `~/.clyde/usage/statusline.json`. Whole rather than extracted: the hook already carries a Python fallback for JSON because `jq` cannot be assumed, and a status line runs far more often than a hook. Parsing belongs in Swift. Clyde reads `rate_limits`, `session_id`, `model.display_name` and the file's own modification time. Nothing else in the payload is used or kept.

**Advisory, like the hook.** No `set -e`, always `exit 0`, and a snapshot write that fails is logged and skipped. A status line that exits non-zero goes blank in the user's terminal; a wrapper that breaks the user's own status line is worse than no feature.

## The model

`UsageLimits` holds the two windows, each a `UsageWindow` of `usedPercentage: Double` and `resetsAt: Date`, plus `updatedAt: Date`, the `sessionID` that wrote it and the model name. `ProcessMonitor` does not own it; a small `UsageLimitsStore` watches the file with the same `DispatchSource` pattern the permission store uses and publishes the parsed value. The store also drops a window whose `resetsAt` has passed with no newer snapshot — Claude Code does the same in the payload, and a bar showing 84 % of a window that ended an hour ago is a lie.

Derived, not stored:

- **Level:** `normal` below 80 %, `warning` from 80 %, `exhausted` at 100 % or when a live session reports `rate_limit` in its `StopFailure` marker — the hook already writes that, and the session row already shows "Rate limited"; this is the same fact at account level.
- **Staleness:** `updatedAt` older than 30 minutes with no live session is `stale`. With a live session the numbers are at most one turn old and are not marked.

## The full panel

A **Limits band above Activity**, in Activity's own language: the same row height, the same left inset, an icon, the word "Limits", then two meters — `5h`, a 44-point bar, the percentage; `7d`, the same — and a chevron. Twenty-eight points of height. Clicking it opens two rows underneath, one per window: the name ("Session", "Week"), a full-width bar, the percentage right-aligned, and the reset. The reset is a countdown ("resets in 1h 12m") under twenty-four hours and a day and time ("resets Sat 09:00") beyond that, built from `CompactSessionRow.duration` so the two windows agree on how time is written. A footer line under the rows says where and when the numbers came from — "Updated 40s ago from the clyde session" — because without a live session they stop moving and the reader has to be able to tell.

Open or closed is remembered, as Activity's is. The band is absent — not empty, not dashed — whenever there is no snapshot, the snapshot has no `rate_limits`, or the feature is off. This is the honest rendering of "nothing to show" and it keeps every panel that has no limits looking exactly as it does today.

The summary bar and the header are unchanged. The header was drawn with the meters and rejected: it already drops its words at three states and four buttons, and limits are not a session state. The summary bar was drawn and kept as a possible later addition, not a placement: it would displace the session count and collide with the advisory chip.

## Compact

Compact has one footer and no header, and the footer already holds the mascot, up to three pills, an optional advisory chip and the way back. Two labelled meters with percentages on top of that come to 440 points in a 400-point window; that was measured, not guessed.

So compact shows **the session window only**: `5h`, a 28-point bar, the percentage, between the pills and "Expand", behind a hairline. The session window is the one that changes within a sitting and the one that ends a task mid-turn; the week is a tooltip away and in the full panel. When the footer is crowded — the same rule that already turns the pills into dots — the `5h` label goes and the bar and percentage stay. The window's height never changes for this.

## The widget

**No change.** The widget says one thing, the dominant session state, and every addition drawn — a bottom hairline, a threshold-only line, a percentage in the corner — argued with that one thing in 130 points. Limits live in the panel that opens from it.

## Colour and thresholds

Three levels, no new colours:

- **Below 80 %:** the neutral white ramp the meters are drawn in.
- **From 80 %:** `SessionTheme.attentionColor` on the bar and the percentage. Blue already means "you will have to do something about this" everywhere else in the app.
- **At 100 %, or on a live `rate_limit` stop:** `SessionTheme.errorColor`, the bar full, the percentage replaced by "full", the reset written as "resumes in 0h 47m".

The first draft of the mockups reached for an amber for the warning level and was corrected the way the compact-mode spec corrected the same instinct: the state already has a colour.

**Stale** dims the meters and the rows to 55 % and changes the footer to "As of 47m ago · refreshes with the next Claude Code turn". The countdown keeps running, because `resets_at` is a date and not a percentage.

## Notifications

Two, both through `NotificationService` and both under the existing snooze:

- once per window when the session crosses 80 %, naming the window and the reset time;
- once when a window that was exhausted resets, so the user who stepped away knows they can come back.

The week crossing 80 % is not a notification; a bar that has been blue since Wednesday is not news on Thursday. Nothing fires for a stale snapshot.

## Settings

One toggle, "Show Claude usage limits", off by default, with the sentence about the terminal side effect underneath, and a line showing the state of the install — the same three-state pattern the permission setting uses: off says where the numbers are instead (`/usage`), on-and-installed says when the last snapshot arrived, on-but-nothing-has-ever-arrived says that a Claude Code turn on a Pro or Max plan is needed. Turning it off uninstalls the wrapper and restores the user's own status line command.

## How this is verified

Unit tests: parsing the snapshot (present, absent, one window missing, `resets_at` in the past); the level and staleness rules; the reset formatting at the twenty-four-hour boundary; the installer against a `settings.json` with no status line, with the user's own status line, and with an unparseable body. The installer tests run under `AppPaths.homeOverride`, as the hook installer's do, so `swift test` never touches the real `~/.claude`.

Hook-style smoke test: pipe the documented status-line JSON into the wrapper with `HOME` pointed at a temp dir, once with and once without a passthrough command, and check the snapshot and the printed line.

The real check is live, and it cannot be rushed: the feature on for a working day, on a Max plan, watching whether the numbers track `/usage`, whether the footer gets crowded on a real three-state session list, whether the 80 % notification lands once and not on every turn, and what the terminal looks like to someone who had no status line before. The last of those is the one most likely to change the default of the toggle.

## Risks worth naming before building

**The status line slot is shared.** A user who installs another status line after Clyde's will silently drop Clyde's wrapper, and one who edits settings by hand may break the passthrough. The health check covers the first; the second is why the wrapper stores the passthrough command outside `settings.json` rather than inside its own script.

**The payload is documented but young.** `rate_limits` was added to the status line input in the 2.1.x line; users on older Claude Code get no object and therefore no band, which is the correct failure. If the field names change, the parser fails closed and the band disappears rather than showing wrong numbers.

**Nothing here works without a Claude Code turn.** A user who opens Clyde on Monday morning after a weekend sees Friday's numbers, dimmed, with a countdown that has run out. That is by design and the stale state exists for it, but it will be reported as a bug at least once; the footer wording is the defence.
