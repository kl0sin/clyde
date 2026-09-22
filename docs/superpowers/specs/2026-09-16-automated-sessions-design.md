# Automated sessions — design

**Status:** agreed in conversation on 2026-09-16 from a field report; ready to plan.

**Phase:** v0.10.0

## What happened

On 2026-09-10 a machine running v0.9.2 played the "ready" sound dozens of times in three minutes and the widget filled with rows called `workspace #1`, `workspace #2`, … The hook log for that window shows 29 Claude Code sessions starting within about two minutes: six in the same second from `/private/tmp/workspace` with consecutive PIDs, then twenty-one in forty seconds from a project directory. Each lived 15–60 seconds, ran one to four turns, and ended with `SessionEnd`. There were 45 `Stop` events, and Clyde plays a sound on every busy-to-idle transition.

Nothing in Clyde misbehaved. Something in the user's project — a Node/Python service or its tests — spawned Claude Code programmatically and in parallel, and Clyde reported every one of those sessions the way it reports the one in the user's terminal. That is the wrong default: those sessions are not waiting for anyone, will never ask for permission from a person, and finish on their own. Their sounds are noise, their rows are clutter, and their counts on the widget misstate what the user has to attend to.

## The signal

The hook payload does not say whether a session is interactive; the documented fields are `session_id`, `cwd`, `permission_mode`, `source` and friends. Two signals outside the payload do, both verified on the user's machine:

- **Standard input.** The interactive TUI needs a terminal on stdin, and has one: `lsof -a -p <pid> -d 0 -Fn` reports `/dev/ttys005`. A session a program started reads from a pipe or `/dev/null` — verified with `claude -p` spawned from a process without a terminal. This is the primary signal. (A process's *controlling* terminal was tried first and rejected: a server started from a terminal hands that terminal down to every `claude` it spawns, while their stdin is still a pipe.)
- **`CLAUDE_CODE_ENTRYPOINT`.** The interactive CLI exports `cli`; the Agent SDK exports `sdk-ts` or `sdk-py`. Hooks inherit it. Undocumented, so it is a confirmation, not the basis.

A session is **headless** when its `CLAUDE_CODE_ENTRYPOINT` starts with `sdk`, or when the `claude` process's standard input is not a terminal device. A `claude -p` run by hand from a terminal keeps its terminal and stays an ordinary session, which is right: the person who typed it is watching it. Cleat sessions are never classified by stdin (their host PID is the cleat shell, not `claude`); only the entrypoint rule applies to them. The lookup runs only where `-info` is written (`SessionStart`, and the `UserPromptSubmit` backfill), not on every event.

## What Clyde does with it

**The hook records it.** `-info` gains `"headless": true` when the session is headless, appended the way `runtime` is, so the file stays byte-identical for ordinary sessions. The always-on log line gains `headless=true` at the end, after `source`, so existing greps keep working. The hook version bumps.

**The monitor hides them.** `ProcessMonitor` keeps tracking every session — liveness, ghosts, revival on resume, the state markers — but what it publishes as `sessions` excludes headless ones, and it publishes `automatedSessionCount` beside it: live headless sessions, ghosts excluded. Everything downstream — the widget, the panel, compact, the menu, the Activity trail, the sounds, the notifications, the push service — reads `sessions` and needs no change to stop seeing them. `clydeState` is computed from the published list, so the widget's face stops reacting to them too. A session that becomes idle is announced only if it is published.

**The panel says how many there are.** The summary bar's trailing text, today `3 sessions`, becomes `3 sessions · 6 automated` while any are live, in the same muted colour. Nothing else in the UI mentions them: compact has no summary bar and the widget has no room, and the point of hiding them is that they do not need attention.

**A setting shows them.** Settings › General › Monitoring gains "Show automated sessions", off by default, with one sentence: "Sessions started by programs rather than from a terminal — the Agent SDK, `claude -p` in a script, a test suite. Off keeps them out of the panel, the counts and the sounds." On, they are ordinary sessions in every respect, sounds included, and the summary bar stops counting them separately. Flipping the switch re-publishes immediately; no restart.

**History is untouched.** The hook's history spool records every session, headless or not; the review window is a record of what ran on the machine. Whether that should also distinguish them is a later question.

## Verification

Unit tests: the hook, driven as a subprocess, writes `headless` under an `sdk-py` entrypoint and under a piped-stdin override, and omits it under a terminal override (the test seam is an environment variable the hook honours over `lsof`, because a test runner may or may not own a terminal). `ProcessMonitor`, driven by writing `-info` files into a temp `stateDir`, hides a headless session from `sessions`, counts it in `automatedSessionCount`, does not fire `onSessionBecameIdle` for it, and publishes it once the setting closure returns true.

Live: reproduce the report — run three `claude -p 'say hi'` in parallel from a script with stdin redirected from `/dev/null`, watch the widget stay still and silent and the summary bar say `· 3 automated`; then the same from the terminal foreground and see an ordinary row. The scenario goes into `scripts/dev/scenarios.sh`.

## Risks worth naming

**The stdin rule is a heuristic.** It holds because the interactive TUI cannot run without a terminal on stdin, but a wrapper that feeds an interactive session through a pseudo-terminal it owns would look interactive, and `lsof` costs a few tens of milliseconds per `SessionStart`. The setting is the escape hatch for whatever the rule misjudges, and the summary bar's count says that something was hidden.

**Attention from a headless session.** A permission request from one still writes an event file. The attention monitor looks the PID up in the published sessions and finds nothing, so no alert fires; the request times out in the hook as it does when Clyde is absent. That is the intended behaviour, and worth one test.

## Revised 2026-09-22: the signal is the arguments, not stdin

The stdin rule shipped in v0.10.0 and misfiled two kinds of session a person is watching within a day: the desktop app's (a pipe from the app) and the background supervisor's (`/fork`, `/bg`, `claude --bg`, or `←` on an empty prompt — hosted under `claude daemon run`, stdin from a pty host). The second also exposed that those sessions name their process `claude bg-spare`, which neither the hook's ancestor walk nor the app's identity check accepted, so they had no `-info` at all and every one of their hooks logged `WARN no claude ancestor`.

A session nobody watches is one started in print mode, and that is in its arguments every time: `claude -p …` from a script, and the SDK, which runs the CLI with `--print`. The rule is now: headless iff `CLAUDE_CODE_ENTRYPOINT` starts with `sdk`, or the `claude` process's argv carries `-p` or `--print` before any `--`. Cleat sessions still use only the entrypoint clause; an empty `ps` answer still fails toward visible. Nothing a launcher does to stdin can hide a session. The `claude-desktop` special case is gone because it is no longer needed. Both identity checks accept a process whose name's first word is `claude`. Hook v49, app v0.10.1.
