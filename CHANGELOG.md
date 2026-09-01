# Changelog

All notable changes to Clyde are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and Clyde uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Sparkle reads each version's section from this file and shows it inside the "Update available" sheet, so write entries for end users — not for yourself.

## [Unreleased]

- **A session no longer announces it has finished when its agent hands work back.** Claude Code ends the parent's turn while its agents keep running, which clears the marker Clyde reads as "working" — so for the second or two between an agent returning and the parent picking the work back up there was no evidence of work at all. The session went green, played the "session finished" sound, and went back to working. It now stays working across that handover.
- **A session's agents are marked by a face, not a dot.** The chip beside a working session read `◉ 1`, and at that size the character is a dot — it said "something", not "an agent". It is a small head with two eyes now, drawn on whole points like every other mark in the app.
- **An agent's mark lines up with its name.** The sprite beside a subagent's row sat two and a half points below the line of text next to it.

## [0.9.0] — 2026-09-01

Clyde has spent three releases answering what your Claude sessions are doing. This one changes what you can do about it. A fourth window keeps the session rows and nothing else, small enough to leave open beside the work it reports on — and when Claude asks permission to run something, you can answer it there, on the session that asked, without going back to the terminal. Underneath both, the two windows that had drifted into two designs are one again: rows in both, ordered the same way, drawn on the same surface, with a status mark that says what a session is doing rather than only which state it is in.

### Permission requests

- **Answer a permission request from the panel.** When Claude asks to run something, the question opens on the session that asked it, with the command shown in full — wrapped rather than shortened, because a shortened command invites approving what you did not read. Allow or Deny, and the session carries on. You have ten seconds; miss it and the terminal asks exactly as it always has, so nothing is lost. Clyde never decides on its own, and the whole thing is off until you switch it on in Settings.
- **It costs nothing when it is off, and nothing when you miss it.** The hook only waits while Clyde is running with the setting on; otherwise it does not pause at all. Ten seconds was four until the first real session proved four was not enough time to notice a row, read a command and click.

### Compact mode

- **A fourth way for Clyde to sit on your screen: the session rows, and nothing else.** The panel is built to be opened, read and closed — a header, an activity trail and a summary bar take four hundred of its points before a single session is drawn. Compact mode drops all of it and keeps the rows, small enough to leave open beside the work it is reporting on. Switch with the button in the panel's header; ⌃⌘C toggles whichever mode you used last, so the shortcut still means "show me Clyde", and the mode and position survive a restart.
- **The window is exactly as tall as it needs to be.** Its height follows the number of sessions, and it grows downward so the top edge stays where you put it. Over a limit you set (four rows by default) the quiet sessions drop off the bottom — never one that is working, and never one that is waiting on an answer, because those sort above them.
- **Permission requests can be answered without leaving compact.** The question opens under the session that asked it, with the command wrapped rather than shortened, and the window returns to its size once you have answered. Deferring to the terminal would have meant the feature you switched on does not work in the window you keep open.
- **A session waiting on you is always at the top.** Both windows now list sessions the same way: whoever needs an answer first, then whoever is working, then everyone else — and inside each group, the order you dragged rows into. The two panels used to disagree, so the same four sessions read differently depending on which one you had open.
- **Rows arrive, leave and change places instead of teleporting.** A session that starts working moves to its new position visibly, so you can see which row moved and where it came from. All of it stops under macOS's "Reduce motion".

### Everywhere

- **A working session is drawn rather than dotted.** The coloured dot said which state a session was in and nothing about whether anything was happening. In its place is a grid of pixels with light crossing it on the diagonal — moving while a session works, holding still and filled when one needs an answer, and giving way to the session number when it is quiet. The state survives the colour being taken away, which a dot never managed, and it is the same mark at both sizes in both windows.
- **Both windows are one design.** They had drifted into two: cards in one and rows in the other, different orders, different marks, different surfaces. Sessions are rows in both now, drawn on the same surface, ordered by the same rule.

### Session review

- **A branch is not a project.** Working in a git worktree put a second entry in the projects list — the same repository, listed again under the branch's directory, with the hours split between them. Worktrees now fold into the repository they came from, and the row names the branches the time was spent on. History recorded before this is folded on the way out, so the split does not persist for as long as the history does.
- **The calendar uses the width it has.** Its cells were a fixed size, so the grid stopped a third of the way across the window and left the rest of the row empty. It now grows to fill whatever width the window is given.
- **The report opens on the two things it is for.** The calendar and the projects, with the activity trail closed behind a heading you can open when you are looking for one particular call. Past five projects the list scrolls inside its own box rather than pushing everything below it off the page, and the report itself scrolls too — with more than a few projects the list used to run off the bottom edge with no way to reach the rest of it.
- **Projects carry a mark.** A coloured square with the project's initial, in the same shape a session's row uses. The colour comes from the name, so a project keeps it across periods and you learn it — and it is drawn from a set that avoids the colours which already mean working, waiting and needs-you.

### Sessions Clyde reads right

- **An interrupted session stops showing as working.** Pressing Ctrl+C while Claude is writing emits no hook event at all — it is indistinguishable from finishing — so the session stayed "working" until the next prompt, or indefinitely if you walked away. Clyde now stops believing a busy marker that nothing has touched for fifteen minutes while no tool is running and no agent is working. It goes quiet without claiming the session finished, because it did not.
- **A session in a worktree keeps its project's name.** When Claude creates a worktree it moves the session into `<repo>/.claude/worktrees/<name>`, and Clyde named sessions after their folder — so a session working in `work-hub` renamed itself to the branch, showed that same word again in the worktree badge, and the project it belonged to was nowhere on the row.
- **A session keeps its project's name when a command changes directory.** Claude Code emits a `CwdChanged` event when a shell inside a tool call runs `cd`, and Clyde renamed the session after it — so a session that briefly visited a temporary directory was listed under that directory's name from then on, permanently, even though every event afterwards carried the real project path. The name now comes from those events instead, which makes it self-correcting: a session that really has moved is renamed by the next thing it does, and one that only wandered for a moment never loses its name.
- **A session is not "ready" while its agents are still working.** The busy marker is cleared when Claude's own turn ends, but subagents routinely outlive it, so a row could read ready beside a spinning agent — and the "session finished" notification fired while four of them were still running. An agent that has gone idle does not hold the session open.

### The shortcut, and what it needed

- **⌃⌘C works.** The global shortcut needs two separate macOS permissions, and Clyde only ever asked about one. With accessibility granted the banner cleared, the shortcut still did nothing, and there was no way to find out why — input monitoring, which is what lets an app see key presses outside its own windows, sat empty and unmentioned. Clyde now checks both and the banner sends you to whichever pane is missing.
- **The shortcut survives Caps Lock.** It was matched by comparing the modifier keys for exact equality, and macOS counts Caps Lock among them, so ⌃⌘C did nothing whenever Caps Lock happened to be on. It is now matched on the C key itself.


## [0.8.2] — 2026-08-30

Two fixes for focusing a session's terminal — the click that brings its tab to the front.

- **Clicking a session finds its terminal more reliably.** Focusing a session's tab is driven by AppleScript, and the script asked for its terminal by name — which fails outright, and silently, when macOS cannot resolve that name to an app. Both the script and the detection that runs before it now go by bundle identifier, the same one the adapter already declared. Working out which terminal hosts a session no longer guesses from the executable's path either: a process whose path merely contained "stable" was handed to Warp.
- **Warp Preview counts as Warp.** Only the stable channel's identifier was known, so on a Preview install Clyde reported the terminal as not installed and refused to focus anything.


## [0.8.1] — 2026-08-30

A fix for a regression in 0.8.0: on many Macs the expanded panel opened at more than three times its intended height, running off the bottom of the screen and taking the Activity bar with it. If that is what you have been looking at, this is the release that fixes it.

- **The panel is the size it says it is again.** In 0.8.0 it could open at 400×1476 instead of 400×420 — tall enough to hang off the bottom of the screen, with the Activity bar and the summary line out of reach below the edge. The session list is a scrollable area with no fixed height, and macOS was sizing the whole window to fit it. Both the panel and the widget now decline any size but their own.
- **A history database that cannot be read can be rebuilt.** Until now a corrupt file meant history was switched off for good: the review greyed out and Settings could only tell you it was unavailable. Settings → Advanced now offers "Rebuild database", which moves the unreadable file aside — it is never deleted — and starts a fresh one. Anything still waiting in the spool is picked up straight away.


## [0.8.0] — 2026-08-29

Clyde has always answered what Claude is doing right now. This release adds the other question: what it did. A new Session review window keeps a local history of your sessions and reports where the day went — how long Claude was busy, how much of that was the model rather than your test suite, which projects took the time, and the moments you and Claude spent waiting on each other. Alongside it, sessions that were never really there stop appearing, and one that started before Clyde did now shows up while it works.

### Session review

- **The review window opens on a calendar of your activity.** Six months of days, one square each, shaded by how long Claude worked — the shape you already know from a contribution graph. Hovering a day tells you the date, the time worked, the number of turns and which project took most of it; days with nothing recorded say so rather than hiding among the quiet ones.
- **"Busy" says what it was made of.** The headline figure was never time the model spent thinking: it is wall-clock with a turn open, so a minute of it can be a test suite your machine ran. A bar under the tiles now splits it — `Thinking 21m · Tools 34m` — using the duration Claude Code reports for every tool call. Parallel calls inside one turn are counted once, not once each. Days recorded before this release have no split and show none, rather than being drawn as if every second were thinking.
- **The other numbers answer questions you can act on.** Running totals mislead: "waiting on you" reads fourteen hours if you leave a session overnight, and a session count told you nothing at all. In their place are the two worst moments of the period — the longest single wait, when Claude sat idle on you, and the longest single turn, when you sat waiting on Claude.
- **An Activity list shows what Claude actually did**, newest first: the time, the tool and what it ran. Clicking a project narrows the list to it. The numbers above deliberately keep describing the whole period, so filtering the list never quietly changes what they mean.
- **A per-project breakdown** of time, turns and the tool each project leaned on.
- **History stays on your Mac, indefinitely.** Settings shows what it costs and clears it behind a confirmation. Nothing from your conversations is stored — only the same tool names and summaries the panel already shows you.
- **Reachable from the panel**, not just the menu bar: a calendar button sits beside the Activity header's chevron, and the welcome screen names the feature.
- **It looks like the rest of Clyde**, rather than a system form: the mascot header, the app's own palette and typography, and figures that hold their place instead of shuffling as they update.

### Sessions Clyde gets right now

- **No more sessions that were never there.** Clyde used to treat any running program named `claude` as a Claude Code session, without checking whether it was one. Its own test suite trips that — and so does anything else on your machine with that name — so the panel could fill with rows named after a directory, none of which ever showed as working, each lingering as "Ended" after it vanished. Sessions are now recognised from what Claude Code actually reports, so a row appears when there is genuinely a session behind it.
- **Sessions that started before Clyde did now show up while they work.** Previously such a session stayed invisible until you sent it your next message, even if it was busy the whole time. It now appears within seconds of doing anything.
- **A session running a single agent shows it.** The panel announced agents only from two upwards, so one agent working on its own looked like nothing was happening. It now reads `1 agent · 0:12` with the agent listed underneath, the same as any larger group.

### First run, and the shortcut that did nothing

- **Clyde now tells you when the ⌃⌘C shortcut can't work.** The global shortcut needs accessibility access from macOS, and without it macOS silently ignores the keypress — so the shortcut Clyde advertises on first run simply did nothing, with no explanation. Clyde now notices and shows a dismissable banner with a button that takes you straight to the right System Settings pane. Everything else keeps working; only the shortcut needs the permission.
- **The welcome screen describes what Clyde actually does now.** It still advertised the v0.2 feature set and said nothing about the tool line, plan progress, subagents or the badges added since. It also warns up front that macOS may ask for accessibility access, which is the most likely reason a new install seems to ignore the shortcut.

### Under the hood

- **The activity calendar no longer stalls on a real history.** Picking each day's busiest project re-ran a query across the whole six-month range once per day — unnoticeable on a week of history, and over two minutes on a year of it, which is a calendar that never appears.
- **The history spool no longer grows without limit.** Only a running Clyde empties it, so leaving the hook installed while the app sits unused meant a file that grew forever. It now stops at 10 MB and keeps everything already recorded, which is ingested the next time Clyde runs.

## [0.7.1] — 2026-08-27

A bugfix release, and the headline is one you would rather never have needed: Clyde could overwrite your Claude Code settings. It took an unreadable `settings.json` to trigger it, but when it did, the file came back holding nothing but Clyde's own hooks. That is fixed, along with three smaller faults found while auditing the same code — all of them the kind that stay invisible until the day they aren't.

- **Clyde can no longer overwrite your Claude Code settings.** If `~/.claude/settings.json` couldn't be parsed — a truncated write, a stray comma from a hand-edit — Clyde treated it as an empty file and rewrote it with nothing but its own hooks, taking your model, permissions, environment, plugins and MCP servers with it. It now refuses to touch a settings file it can't read and reports the problem instead. Clyde's own writes to that file are atomic too, so an interrupted one can no longer truncate it in the first place.
- **The session row says what a command is actually doing.** A shell command's summary was its first 40 characters, so anything starting with an environment variable or a `cd` into a long path filled the row with noise — `Bash · SP=/private/tmp/claude-501/-U…` — and never got to the command itself. Those prefixes are skipped now, while anything ambiguous is left alone rather than guessed at.
- **A hook script with no version stamp is repaired instead of ignored.** Clyde compared version numbers only when it could read one, so a script damaged into losing its stamp was never upgraded and never reported — it just quietly stopped keeping up. Clyde now spots it and replaces it on the next launch.
- **Leftover session files are cleaned off disk.** Clyde stopped showing subagent rows older than 30 minutes but never deleted them, so the files accumulated and each one re-announced itself in the log on every poll. Directories left behind by sessions that crashed without shutting down cleanly are now collected too.

## [0.7.0] — 2026-08-27

Clyde's hook coverage stopped growing while Claude Code kept getting more autonomous, and the gap showed up exactly where it hurts: agent teams, batches of parallel tool calls, slash commands driving long unattended runs. This release closes it. The session row stops saying "Working" and starts saying what is actually happening — which command is running, which worktree it is running in, how many tools are in flight, and what Claude said when it finished. It also fixes the one place where Clyde's model of a session was provably wrong: subagents were tracked through the tool call that dispatched them, so a backgrounded agent vanished from the panel while it carried on working. Clyde's hook script upgrades itself on launch; nothing to reinstall.

- **Subagents no longer disappear from the panel while they're still working.** Clyde tracked each in-flight subagent through the tool call that dispatched it, which held up right until Claude started running agents in the background — those calls return the moment the agent is handed off, so Clyde tore the row out of the panel while the agent carried on working. On a real session the gap measured five seconds; for a long-running agent it's minutes of the panel claiming nothing is in flight. Clyde now follows the agent's own identity instead, so a row appears when the agent is dispatched and disappears when the agent actually finishes.
- **Parallel tool calls now show up as parallel.** Claude often runs several tools at once. Clyde used to track only one of them, so the row showed whichever call happened to register last and went blank the moment the first of them finished — even with three still running. Each call is now tracked separately: the row reads `3 tools · 0:04` while a batch is in flight and only clears when the last one is genuinely done.
- **The running slash command is named on the row.** Start a long `/loop` or `/code-review` and the session shows an amber `/loop` badge next to the project name instead of an anonymous "Working", so you can tell at a glance which of your sessions is grinding through what.
- **Worktree sessions are labelled.** A session working inside a git worktree gets a green badge with the worktree's name, instead of showing an opaque `.claude/worktrees/…` path. The badge drops the moment the session leaves the worktree.
- **Idle sessions show Claude's last reply.** Instead of repeating the project path, an idle session's second line now previews the first line of what Claude last said.
- **Skill, Workflow and Artifact calls are named.** These three used to render as a bare tool name; the row now shows which skill, which workflow and which page.
- **Agent-team teammates that go idle now show as idle.** When a teammate on an agent team is about to go idle, its row in the panel settles instead of pretending work is still in progress — the little mascot stops animating, the duration stops counting, and the label reads `idle`. The row stays put, so you can still see who is on the team and what they were doing. This is intentionally a quiet state and not an alert: Clyde won't light up the "needs your input" badge for it until we know how often the event really fires.

## [0.6.0] — 2026-06-09

Clyde can now start itself. A new "Launch at login" toggle in Settings → General registers Clyde with macOS so it's already sitting in your menu bar when you sign in — no more remembering to launch it before kicking off a Claude session.

- **Launch at login.** Settings → General gains a Startup section with a single switch. Flip it on and macOS starts Clyde automatically at sign-in, using the system's native login-items registration (`SMAppService`, macOS 13+) — the same mechanism you see under System Settings → General → Login Items, where Clyde shows up and can be managed too. If macOS requires your explicit approval for the registration, Clyde shows an inline "Approval needed" hint with a button that jumps straight to the Login Items pane instead of pretending the toggle worked. State stays in sync both ways: flip it in System Settings and Clyde's toggle reflects the change the next time you open Settings.

## [0.5.3] — 2026-05-21

Iteration on the cleat advisory banner introduced in v0.5.0 — it now refreshes live as you toggle cleat's host hook bridge, splits the message into a readable title + body, surfaces the fix command as a one-click copyable chip, and gains an × button if you want to silence it for the session.

- **The cleat advisory banner is now a proper card.** Title-bold headline ("Cleat hook bridge is off"), softer body underneath, and the fix command lives in a discrete copyable chip — click it to drop `cleat config --enable hooks` straight into your clipboard, with a brief ✓ confirmation. The old inline-backtick rendering was hard to read against the orange banner; the chip has a proper rounded background, clipboard icon, and tap-to-copy affordance.
- **Banner appears and disappears live.** Toggling cleat's `hooks` capability via `cleat config --enable/--disable hooks` now reflects in the panel within ~0.3s instead of waiting up to 60s for the safety-net timer. Implemented via a pair of FSEvents watchers on `~/.config/cleat/` — one on the directory (catches the disable path, which recreates the file) and one on the config file itself (catches the enable path, which writes in place — the dir watcher alone would miss it).
- **Dismiss button on advisory banners.** A small × in the banner's top-right snoozes the cleat advisory for the current Clyde session. The banner reappears on relaunch, or if you toggle the cap on and then off again — handy for "I'll deal with it later" without losing the reminder permanently. Critical hook-health banners (script missing, outdated, etc.) stay non-dismissable since they break tracking entirely. Dismiss state lives in memory only — no settings to clear, no persisted state to debug.
- **No more misleading "Click to open Settings" on the cleat banner.** Settings can't run `cleat config` for you, so the affordance pointed nowhere useful. Actionable banners (the ones whose fix lives in Settings) keep their click target; advisories render as informational rows. Internal: hook script bumped to v27 (no behaviour change — just version-stamped with the latest fix from v0.5.2).

## [0.5.2] — 2026-05-21

Follow-up to v0.5.1: the "Needs Input" badge no longer false-positives on every routine reply. Turns out `Notification("Claude is waiting for your input")` isn't an attention signal — Claude fires it after every `Stop` in bypass-permissions mode as a plain idle marker, so v0.5.1 lit the badge up on every turn including the most boring "here's your answer" ones.

- **"Needs Input" badge no longer fires on idle replies.** v0.5.1 mapped `Notification("Claude is waiting for your input")` onto the attention indicator on the theory that it's Claude explicitly saying it's waiting for you. In practice Claude fires that exact message after every `Stop` in bypass-permissions mode (cleat's default), including routine turns where nothing actually needs your attention — so the badge ended up showing on every reply. v0.5.2 drops that string from the match. The permission-flavoured forms ("needs your permission to use …") still trigger the badge as a safety net for non-bypass builds where they could be the only attention surface. Existing stale badges from v0.5.1 clear themselves the next time you reply in the affected session — no manual cleanup. Hook script bumped to v27.

## [0.5.1] — 2026-05-21

Quick follow-up to v0.5.0 — the "needs your input" badge now lights up for sessions running in `--dangerously-skip-permissions` mode (most commonly [cleat](https://github.com/cleatdev/cleat)-sandboxed ones), which previously sat dark in the panel even when Claude was waiting on you.

- **"Needs your input" badge now fires in bypass-permissions mode.** Claude Code doesn't fire `PermissionRequest` when running under `--dangerously-skip-permissions` (cleat's default, and the whole point of the sandbox). It fires `Notification` with `message: "Claude is waiting for your input"` instead. Clyde used to treat every Notification as log-only; hook v26 now matches that message (plus the alternate "Claude needs your permission to use …" form) and surfaces the same orange attention indicator you'd see for a regular permission gate. The badge drops the moment you reply — `UserPromptSubmit` now sweeps the attention flag too, so it doesn't linger on plan-mode or pure-text turns where no tool call fires immediately afterwards.

## [0.5.0] — 2026-05-20

First-class support for Claude Code sessions running inside [cleat](https://github.com/cleatdev/cleat) — the Docker sandbox that lets you run `claude --dangerously-skip-permissions` without risking your host — plus a small UI fix that stops the progress and runtime badges from getting visibly clipped on long project names.

- **Now tracks sessions running inside [cleat](https://github.com/cleatdev/cleat).** Cleat sandboxes Claude Code in Docker so it can run with full autonomous permissions without touching your host — same productivity, zero blast radius. Clyde now detects cleat-sandboxed sessions automatically and renders them in the panel like any native session, with a small cyan **cleat** badge next to the project name so you can tell them apart. Working directories show as the real host path (no more `/workspace` mystery), and liveness tracking is wired to the cleat process on the host so sessions age out correctly when you close your cleat terminal. If you have cleat on your PATH but haven't enabled its host hook bridge yet, Clyde surfaces a one-line banner pointing at `cleat config --enable hooks` so sandboxed sessions actually reach the panel. Big thanks to the cleat team for shipping a tool that makes autonomous Claude actually safe to leave running overnight — go check it out at [github.com/cleatdev/cleat](https://github.com/cleatdev/cleat). Hook script bumped to v25; existing installs auto-upgrade on Clyde launch.
- **Plan and cleat badges no longer get clipped on narrow rows.** SwiftUI was happy to give the project-name label all available horizontal space and squeeze the capsules past their content box, so the progress icon or the "cleat" tag would render visibly cut off on the right edge for projects with longer names. Both badges now refuse to compress; the name takes the ellipsis instead.

## [0.4.0] — 2026-05-14

Parallel subagents land in the panel, plus a UI polish pass and a fix for the long-standing "Home" mislabel on sessions Clyde discovered through `pgrep`.

- **Parallel subagents in the panel.** When Claude fans out to several subagents at once via the built-in `Agent` tool, the session row now flips its second line to e.g. `5 agents · 0:12` and renders a lavender-accented list of each in-flight subagent underneath — type and live duration on one line, the short Claude-supplied description on the next. Each row gets a static pixel-art mini-mascot so the affordance reads as part of the same visual family as the main indicator. Lists longer than three collapse behind a `+N more agents` tap; the list auto-collapses again once activity drops to three or fewer. Defensive 30-minute GC drops zombies left behind by crashed parents, and the legacy single-subagent indicator keeps working for sessions started before this build.
- **Real project names for sessions discovered through `pgrep`.** Clyde used to mislabel any session whose `.claude/settings` heuristic only matched the global `~/.claude/settings.json` as "Home". The new detection asks `lsof -d cwd` for the process's actual working directory first, so a `claude` running in `~/_Projects/pulse` shows up as "pulse" instead. The settings-based heuristic stays as a fallback for older Claude builds that chdir'd to `/`, and the global `~/.claude/settings.json` is now explicitly rejected from that fallback so it can no longer impersonate a real project.
- **UI polish pass on the session row.** Design tokens for text colours unified across the row, hover states gain proper feedback, and the row no longer jumps vertically by a pixel when the rename pencil appears on hover. The subagent block spans the row's full width (so per-agent durations right-align with the trailing "Working · Ns" indicator), the mascot and right-side status both anchor to the top of the row instead of drifting down as the subagent list grows, and all secondary text in the block matches the existing 10pt monospaced typography of the tool/path indicator.
- **Hook script v21.** Claude Code emits `tool_name="Agent"` on subagent dispatch (the older `"Task"` name no longer ships). The Pre/Post lifecycle, summary line, and defensive cleanups in `clyde-hook.sh` now match on `Agent` (with `Task` retained as a defensive fallback). Existing installs auto-upgrade on Clyde launch; no manual hook reinstall needed.

## [0.3.1] — 2026-04-30

Onboarding plus accessibility plus a plan-badge fix on top of v0.3.0. Same feature surface — same panel, same hooks, same telemetry — just easier to discover and to use, regardless of how you read the screen.

- **First-run coachmark tour.** After the welcome modal Clyde now walks you through the four things that aren't obvious at a glance — what each session row shows and means, the live `Edit · MyFile.swift · 3s` tool/plan line that ticks while Claude works, the snooze button for muting alerts during meetings, and the global `⌃⌘C` hotkey for opening or hiding the panel from anywhere. Skippable mid-tour, replayable from Settings → General, and silent for anyone upgrading from a Clyde version that didn't have it.
- **Accessibility pass.** Every interactive control in Clyde now announces itself meaningfully under VoiceOver — session rows speak their name, status, current tool and plan progress as one breath, the menu-bar capsule reads its live count, and tooltips, snooze remaining time, and onboarding cards all carry semantic labels. With Reduce Motion enabled in System Settings, Clyde stops every auto-running animation: the mascot freezes on its first frame, status pills no longer pulse, and slide transitions become opacity crossfades. Drag-and-drop and color transitions stay intact.
- **Completed plan badges no longer linger.** When Claude finishes a multi-step plan (the green `✓ N/N` badge), the badge now disappears the next time you submit a prompt instead of sticking around through every subsequent unrelated turn. Partial plans still persist across turns so the progress badge keeps tracking when you type "continue" mid-execution — only fully-completed badges get cleared.

## [0.3.0] — 2026-04-29

Richer session telemetry. Clyde stops at "is Claude busy?" and starts answering "what is Claude actually doing?" — every session row now narrates the active tool with a live duration, and surfaces plan-then-execute progress when Claude maps out a multi-step run.

- **The session row now shows what Claude is actually doing.** When Claude calls a built-in tool — `Edit`, `Write`, `Read`, `Bash`, `Glob`, `Grep`, `Task`, `WebFetch`, `WebSearch` — the second line of the row swaps from the project path to e.g. `Edit · SessionRow.swift · 3s` with a spring slide animation, ticking the duration live. When the tool finishes the path slides back in. TodoWrite and MCP tools show just the tool name (no summary), so the indicator is silent only on truly unidentifiable activity. Powered by a new hook event capture (`-tool` state file) — no new IPC.
- **Plan-then-execute progress on the session row.** When Claude maps out tasks via `TaskCreate` (the planning tool), Clyde shows a small `📋 N/M` badge with a progress bar next to the session name. The bar fills as Claude completes tasks and switches to a green `✓ N/N` when the plan is done. The badge persists across turns, so a long plan that Claude works on over several "continue" prompts keeps tracking — no flicker, no reset. Right-click "Reset session state" wipes the badge if it ever lingers after a plan changes direction.
- **"Reset session state" now actually resets.** The per-session reset action in the row's right-click menu used to leave behind `-error`, `-subagent`, and `-tool` markers — only `-info` and `-busy` were cleared. It now wipes every hook-written marker plus any pending attention event, so the manual escape hatch works whether the wedged state is a stale plan badge, a stuck "Working" pill, or a phantom "Needs Input" flag.

## [0.2.3] — 2026-04-29

Small-but-real bugfix and timeline polish pass on top of v0.2.2.

- **No more blank Settings window on launch.** macOS state restoration was occasionally resurrecting SwiftUI's placeholder `Settings` scene (Clyde's real Settings live in a window managed by `AppDelegate`), which surfaced as an empty gray window appearing at random app launches. `NSQuitAlwaysKeepsWindows` is now `false` in `Info.plist` so Cocoa skips restoration entirely — the menu-bar app owns its windows explicitly anyway.
- **Auto-compact and `/clear` now show up in the Activity timeline.** Previously the second `SessionStart` that Claude Code fires after an auto-compact (same PID, fresh context) slipped past the diff silently, so the timeline went quiet right when the most interesting thing was happening. Clyde now tracks the hook `source` field per session and emits a dedicated "Session compacted" entry whenever the source flips to `compact` or `clear`.
- **Hook log records the SessionStart source.** `clyde-hook.sh` (v16) now appends `source=startup|resume|clear|compact` to the always-on hook log, so future investigations don't need to correlate `SessionStart` lines with `PreCompact`/`PostCompact` to tell apart a real `--resume` from an in-place auto-compact restart.

## [0.2.2] — 2026-04-27

Quality-of-life pass on top of the v0.2.1 signed release. No new product features — just polish across the install surface, the update dialog, and one real bugfix.

- **Homebrew cask published.** `brew tap kl0sin/tap && brew install --cask clyde` now works, served from [kl0sin/homebrew-tap](https://github.com/kl0sin/homebrew-tap). The release workflow stamps the cask on every signed release, so the tap stays in sync automatically.
- **Sparkle release notes render as HTML.** The update dialog now shows formatted bullets, headings, and bold text instead of raw markdown punctuation. The release pipeline pipes the CHANGELOG section through a small markdown→HTML converter before writing it into the appcast `<description>`.
- **Keyboard Shortcuts section in Settings.** Settings → General now surfaces the discoverable shortcuts (`⌃⌘C` to toggle the panel, `⌘,` for Settings, `⌘Q` to quit), and the same list landed in the README so newcomers can find them without launching the app.
- **Phantom session rows from recycled PIDs are gone.** When macOS reused a dead Claude PID for an unrelated long-lived binary, `discoverPIDs` was only checking liveness — never the argv[0] identity — so the recycled PID kept showing up as a Claude session in Clyde's UI. The discovery path now mirrors the identity check used for `-busy` markers, with regression coverage in `ProcessMonitorTests`.
- **Smoke-test doc covers the permission-denied path.** Scenario 4b walks through `PermissionRequest → PermissionDenied`, where `events/<sid>.json` is dropped instantly instead of lingering on a tool call the user explicitly rejected.

## [0.2.1] — 2026-04-22

First signed and notarized release. No product changes.

- **Gatekeeper-friendly.** Clyde is now signed with a Developer ID certificate and notarized by Apple. First launch no longer shows the "unidentified developer" warning — just open the DMG and drag to Applications.
- **Sparkle auto-updates activated.** The appcast is now live, so future versions will install themselves in the background instead of requiring a manual DMG download.

### Resolved limitations from earlier releases

- Code signing and notarization (called out in 0.1.0 and 0.2.0).
- Sparkle update channel — was dormant in 0.1.0 / 0.2.0, now active.

## [0.2.0] — 2026-04-11

Expanded hook integration, attention reliability, and error visibility.

### Attention & status fixes

- **"Needs Input" no longer vanishes after 60 seconds.** The old mtime-based timeout silently expired attention events even when the permission prompt was still active in the terminal. Attention now persists for as long as the owning Claude process is alive — cleaned up only when the user actually responds (PreToolUse / Stop) or the process dies.
- **Clicking a session row no longer clears "Needs Input."** Previously, `focusSession()` eagerly called `clearAttention()` on click — the badge vanished the instant you tapped the row, even though the prompt was still unanswered. Attention is now cleared exclusively by hook events.
- **Permission denial now clears attention instantly.** Registered the `PermissionDenied` hook so denying a permission prompt drops the "Needs Input" badge immediately instead of waiting for the next `Stop` event.

### Expanded hook integration (v15)

Registered 9 new Claude Code hook events, bringing the total from 9 to 18. Highlights:

- **StopFailure error surfacing.** When Claude hits a rate limit, billing error, server error, or output-token cap, the session now shows a red "Rate limited" / "Server error" / "Error" badge instead of silently sitting on "Working" forever. The error clears automatically on the next successful `Stop`.
- **CwdChanged live updates.** If the user `cd`s to a different project mid-session, the project name in Clyde updates in real time instead of staying stuck on the original `SessionStart` cwd.
- **SessionStart source field.** The activity timeline now distinguishes "Session started" from "Session resumed" and "Context compacted" based on the `source` field in the hook payload.
- **Elicitation as attention.** MCP tools that request user input (forms, dialogs) now trigger the same "Needs Input" badge and notification as permission prompts. Cleared on `ElicitationResult`.
- **SubagentStart / SubagentStop tracking.** When Claude spawns a subagent, the activity timeline logs "Subagent: Explore" (or whichever agent type) and "Subagent finished".
- **Notification, PreCompact, PostCompact** registered for diagnostics (log-only, no UI yet).

### Landing page

- Global ambient lighting layer (`html::before`) replaces per-section radial gradients that were clipped by `overflow: hidden`, eliminating visible horizontal seams between sections.
- Smooth scroll with `scroll-padding-top` so anchor links land below the sticky nav.
- Support card background fixed (`var(--surface)` → `var(--bg-card)`).
- Button icon gap fixed on `.cta-secondary`.
- Feature/install/support sections use gradient-fade slab backgrounds instead of hard-border slabs.

### Known limitations

- Still **not code-signed or notarized** — same Gatekeeper workaround as v0.1.0 (right-click → Open).

## [0.1.0] — 2026-04-09

First public release of Clyde — a friendly menu bar companion that tracks every Claude Code session on your Mac in real time.

### Session tracking

- **Real-time state via native Claude Code hooks.** No polling, no daemon, no privileged helper. Clyde reacts to `SessionStart`, `UserPromptSubmit`, `Stop`, `PermissionRequest` and related hook events within milliseconds of Claude firing them.
- **Three mutually-exclusive states** surfaced per session: `ready`, `working`, `needs input`. Counters in the expanded header and the bottom summary bar never double-count a session that's both busy and waiting on permission — attention always wins.
- **Identifies Claude processes by their actual launch name** (`argv[0]`) rather than the kernel's exec-image basename. This is what lets the `-busy` markers survive poll ticks on real installations, where the binary lives under a version-named directory like `~/.claude/2.1.96/cli.js`.
- **Handles `claude --resume` correctly.** A resumed session reuses its original `session_id` but runs under a brand-new PID — Clyde reconciles the two by `session_id`, revives the ghost row in place, and never shows the old + new rows side by side. A one-tick deferral on pgrep-only PIDs hides the ~500 ms race between the new binary appearing in `pgrep` and the `SessionStart` hook firing, so the visual handoff is seamless.
- **Ghost rows** linger for ~5 minutes after a session ends, so a closed terminal still shows "ended Xm ago" in the list instead of snapping off the screen.

### Menu bar, widget & UI

- **Menu bar capsule** with a pixel-accurate Clyde silhouette plus a coloured count for the dominant state (green = ready, purple = working, blue = needs input). Two smaller ticks show the non-dominant state counts on the right.
- **Floating widget panel** — drag it anywhere on screen, it snaps to the nearest edge, and click to expand into the session list. Hide it entirely from Settings if you prefer menu-bar only.
- **Expanded panel** with per-session rows: custom rename (per-session or per-`session_id`), drag-to-reorder with persistent order, click-to-focus the host terminal, and a live activity timeline at the bottom.
- **Stable row numbering.** Idle rows keep their slot index even when a neighbour flips to `working` — no renumber jitter as sessions transition.
- **Clyde mascot animation** runs in every non-sleeping state now, not only idle. The widget and expanded-header mascots blink / glance ambiently whether you're working, idle, or waiting on a permission prompt, so the app always feels alive.
- **Attention alerts** — sound + macOS notification the moment a `PermissionRequest` fires. Never miss a prompt again.
- **Snooze** (15m / 30m / 1h / 2h) mutes all sounds and notifications for quiet hours. Menu bar shows a `zzz` badge with the remaining minutes while active.
- **Global hotkey** ⌃⌘C to toggle the expanded panel from anywhere.
- **Terminal adapters** for Terminal.app, Warp, and Ghostty — clicking a session in the list focuses the correct hosting terminal window regardless of which one launched Claude.

### Hook installation & self-healing

- **Auto-installs the hook script** into `~/.claude/hooks/` on first launch, with an explicit opt-out toggle in Settings. Users who decline never get re-prompted.
- **Self-heals on every launch.** Clyde's health check detects missing script files, unexecutable permissions, outdated script versions, missing event registrations in `settings.json`, and (new in 0.1.0) matcher-less `PreToolUse` / `PostToolUse` entries that Claude Code would otherwise reject as malformed.
- **Watches `~/.claude/settings.json`** via FSEvents and re-runs the install within ~300 ms when another tool (claude-visual and similar) rewrites the file end-to-end and drops Clyde's entries. Echo suppression prevents a reinstall loop on Clyde's own writes.
- **Legacy migration.** Existing users who installed an older build of Clyde (under the `clyde-notify.sh` filename) get automatically migrated to the canonical `clyde-hook.sh` on first launch of 0.1.0 — the legacy file is deleted, the new script is written, and `settings.json` is rewritten to reference the canonical path.
- **Advisory hook script.** `clyde-hook.sh` no longer propagates intermediate failures — it runs without `set -e`, catches errors via an `ERR` trap, logs them to `~/.clyde/logs/hook.log`, and always exits 0. Claude Code will never again surface a "Stop hook error" line because of our script.
- **Coexists with other hook owners.** `settings.json` merges Clyde's entries alongside whatever else is registered per event (claude-visual, custom scripts, etc.) without clobbering them, and dedupes cleanly across reinstalls.

### Diagnostics & onboarding

- **Detects missing Claude Code** at startup. If `~/.claude/` is absent and `claude` isn't on `PATH`, Clyde surfaces a banner pointing users at [claude.com/claude-code](https://claude.com/claude-code) instead of silently trying (and failing) to install its hook.
- **Reveal hook log** button in Settings → Maintenance. Selects `~/.clyde/logs/hook.log` directly in Finder so users can drag the file into a bug report without navigating by hand.
- **Reveal Clyde data folder** button for inspecting state / events files by hand.
- **Copy diagnostic info** button that collects version, hook state, session count, and recent activity into the clipboard for easy sharing.
- **Reset tracking state** option for when Clyde itself needs a hard reset (wipes `~/.clyde/state` and `~/.clyde/events`).
- **Acknowledgements sheet** in Settings with the verbatim MIT license text for Sparkle, the only third-party dependency.
- **Onboarding flow** on first launch with a welcome screen and a clear explanation of why the notification permission is needed.

### Support & project

- **GitHub Sponsors** integration via `.github/FUNDING.yml`. The repo page renders a "Sponsor" button that points at one-time and monthly tiers.
- **Buy Me a Coffee** link alongside Sponsors for users who prefer a one-off tip without creating a GitHub account.
- **Support section** on the landing page, in the README, and in Settings → Support development — all three surfaces point at the same two links. Entirely optional; there's no paid tier and no telemetry.

### Build & release

- **Universal binary** (Apple Silicon + Intel), macOS 13 Ventura and later.
- **Self-contained Swift Package.** No Xcode project required — `swift run Clyde` builds and runs from a clean checkout.
- **Credential-aware release pipeline.** The GitHub Actions workflow detects whether Apple Developer / Sparkle secrets are present and, if not, produces an unsigned DMG + pre-release automatically instead of failing the run. The same workflow will start producing signed + notarized builds the moment the secrets are added, with zero edits.
- **Bundled Sparkle framework** ready for future auto-updates.

### Quality

- **60 unit tests** covering the hook installer, ProcessMonitor, AppViewModel, SessionListViewModel, terminal adapters, and integration paths. Suite runs deterministically — test isolation via `AppPaths.homeOverride` redirects every filesystem access through a throwaway temp home, so nothing under the developer's real `~/.claude/` is ever touched during `swift test`.
- **Regression coverage for every reliability fix** that shipped in 0.1.0: matcher-less `PreToolUse` entries, legacy `clyde-notify.sh` migration, third-party hook coexistence, `proc_name` vs `argv[0]` identity, `claude --resume` ghost revival, and the pgrep-only deferral path.
- **Manual smoke test document** (`docs/hook-smoke-test.md`) covering six end-to-end scenarios that unit tests can't reach — fresh install, legacy migration, external rewriter, permission prompt mid-flight, session resume, and Stop-hook noise triage. All six pass against the 0.1.0 build.

### Known limitations

- **Not yet code-signed or notarized.** On first launch macOS Gatekeeper will say the app is "from an unidentified developer". Right-click `Clyde.app` → **Open** → confirm in the dialog. macOS remembers the exception so subsequent launches are clean. Proper signing and notarization will ship in a later release.
- **Sparkle auto-updates are dormant.** The framework ships in the binary and the appcast URL is wired up, but the update channel won't find new versions until signed releases start publishing to it. For now, grab new versions from [Releases](https://github.com/kl0sin/clyde/releases) directly.
- **Homebrew cask** is drafted in `Casks/clyde.rb` but not yet published to a dedicated tap repo. `brew install` support will land alongside signed releases.

### Credits

Built in SwiftUI by [Mateusz Kłosiński](https://github.com/kl0sin). Uses [Sparkle](https://sparkle-project.org/) (MIT) for future in-app updates.
