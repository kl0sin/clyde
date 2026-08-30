# Approving permission requests from the panel — design

**Status:** design agreed, one mechanism question open (see *The question the spike answers*). Not yet planned or implemented.

**Phase:** v0.9.0

## What this is

When Claude asks for permission to run a tool, the answer has to be typed in the terminal. Clyde already knows the request happened — it raises the attention badge — but it can only point at it. This phase lets the user answer from the panel: one click for the request in front of them, and nothing else.

The change is small on screen and large underneath. Clyde's hook bus is one-way by construction: `clyde-hook.sh` writes state files, prints nothing on stdout, and always exits 0. Every design note in that script assumes it. The one time Clyde subscribed to a hook that expected an answer back — `WorktreeCreate` in v0.7.0 — every `EnterWorktree` call in the user's session failed with "hook succeeded but returned no worktree path", caught on a live session days before a release. That is the precedent this phase has to respect, on an event that fires far more often.

## Non-goals

**Sending prompts to a session.** Parked in the backlog. No hook event puts text into a running session, so it needs a different mechanism entirely, and whether Clyde should do it at all is not settled.

**A second permission configuration.** A click answers one request. Clyde does not remember decisions, does not learn rules, and never writes to the user's `settings.json`. The `HookInstaller` audit already cost this project one config-loss incident in that file; approving a tool call is not a reason to go back in.

**Replacing the terminal prompt.** The terminal prompt stays the ground truth. Clyde is a shortcut that sometimes gets there first.

## Decisions taken

**The decision window is short — 3 to 5 seconds.** Clyde shows the request, and silence hands the question to the terminal's own prompt. A long window would make Clyde the primary surface, but it also means a session that looks frozen to anyone watching the terminal, and a bug in the hook costs the full window on every tool call. Short keeps the failure cheap.

**A click answers exactly one call.** No "always allow", no session-scoped memory, no persisted rule. Nothing survives the decision, so there is no state to expire, audit, or explain, and a misclick costs one tool call.

**The panel never opens itself.** The widget signals the request the way it signals attention today. Auto-opening would make the feature work regardless of where the user is looking, at the price of a window appearing over their work on every permission request — usually while they are already in the terminal and about to answer there. The cost is real and accepted: with the panel collapsed, the terminal will answer nearly every time.

## The question the spike answers

`PreToolUse` fires on **every** tool call, including the ones that never ask for permission. If Clyde waits on all of them, it adds the full window to every file read. That is not shippable, so the design depends on being able to block selectively.

Three ways out, best first:

1. **`PermissionRequest` accepts a decision.** Then only real requests block and the problem disappears. Whether that event has a response contract is unknown — `PreToolUse` is the documented place for `permissionDecision`.
2. **The hook reads Claude's permission configuration** and waits only for calls that do not match an allow rule. It duplicates someone else's matching logic, which will drift.
3. **Clyde keeps its own list of tools that usually prompt.** Crude, and still slows the common ones.

**Spike, before any implementation:** a throwaway hook in a scratch project that answers `PermissionRequest` with a decision on stdout, run against a real session, to see whether Claude honours it. Half an hour, and it decides the architecture. If the answer is no, option 2 is the fallback and the design below is unchanged apart from where the wait lives.

## How it works

**The request reaches the panel.** The hook's `PermissionRequest` payload carries only `session_id`, `pid`, `cwd`, `event` and `timestamp` today — enough to raise a badge, not enough to answer. It gains the tool name and the full tool input. The panel shows both untruncated: a shortened command invites approving something the user did not read, which is the one thing this feature must not encourage. Long commands scroll within the row.

**The answer goes back.** Clyde writes a decision file under `~/.clyde/` keyed by the request's `tool_use_id`. The waiting hook polls for it within the window, reads it, deletes it, and prints the decision. Polling a file with a bounded wait is what the rest of this architecture already does; a socket would be cleaner and introduces a daemon.

**Nothing else can answer.** The decision file is bound to one `tool_use_id`, is only honoured inside that request's window, and is deleted on read — so a decision cannot be planted ahead of time or replayed. This is the part of the phase that deserves the most care: today anything that can write to `~/.clyde/` can lie to the panel about what it shows; afterwards it can approve the execution of a tool.

**Every failure ends in `ask`.** Clyde not running, a malformed or unreadable file, a half-written decision, the window expiring — all of them fall through to the terminal's own prompt. The hook still never exits non-zero and still never blocks past its window.

## On screen

The request appears on the session's row: the tool name, the command, and two buttons. It clears itself when the window closes, whichever way the answer came — a request answered in the terminal must not leave a dead prompt in the panel.

## Rollout

Off by default, behind a setting, until it has run on more than one machine. Today's v0.8.0 panel regression shipped a defect that could not be reproduced on the development machine at all; a feature that sits in the critical path of every session gets a stronger version of that caution.

## How this is verified

Unit tests cover the decision file's lifetime and every fallback-to-`ask` path. The hook gets its usual smoke test with a fake payload.

Neither proves the thing that matters. The real check is a live session: a permission request answered from the panel, one answered in the terminal while the panel is showing it, one left to time out, and one with Clyde killed mid-window. Those become a `scripts/dev/scenarios.sh` scenario, because every real bug in this project so far was found by putting the app in a state and looking at it.

The measurement that must exist before release: the added latency on tool calls that are **not** permission-gated. If the spike lands on option 2 or 3, that number is the feature's real cost and it belongs in CI, not in someone's memory.
