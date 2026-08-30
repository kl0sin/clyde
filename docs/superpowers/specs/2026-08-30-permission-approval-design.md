# Approving permission requests from the panel — design

**Status:** design agreed, mechanism settled by spike on 2026-08-30. Ready to plan. Not yet implemented.

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

## The mechanism, settled

`PreToolUse` fires on **every** tool call, so waiting there would tax calls that never ask for permission. The spike asked whether `PermissionRequest` can carry the decision instead. It can.

`PermissionRequest` fires **only when permission is actually requested**, and a hook answers it on stdout:

```json
{"hookSpecificOutput": {"hookEventName": "PermissionRequest",
                        "decision": {"behavior": "allow" | "deny" | "ask", "message": "..."}}}
```

Not `PreToolUse`'s flat `permissionDecision` — a nested `decision` object with `behavior`. Exit code 2 is not honoured for this event; the decision object is the only channel. The first spike run used the `PreToolUse` shape, Claude ignored it, and the prompt appeared as usual.

Verified end to end: in a session that asks for everything, a hook answering `allow` ran the tool with no prompt — 1.45s from `tool_use` to `tool_result`, against 13s when the answer was ignored and a human had to click. So there is no per-tool-call tax at all, and options 2 and 3 are dropped.

The hook timeout for this event is 600 seconds, not the 60 assumed while writing this. The short decision window is therefore entirely our choice, made for the reasons above, and not a constraint we are pressed against.

### Where this only ever applies

Permission modes decide whether a request happens at all. In `auto`, `dontAsk`, `acceptEdits` and `bypassPermissions`, routine calls never reach the permission system — three of the spike's runs produced no `PermissionRequest` and no prompt for exactly this reason. The feature is meaningful only for users working in a mode that asks, and the panel must show nothing in the modes that do not.

This narrows who benefits, and it belongs in the decision to build it rather than in a footnote discovered later.

## How it works

**The request reaches the panel.** The event already carries everything needed: `tool_name`, the full `tool_input`, `permission_mode`, and Claude's own `permission_suggestions`. It is `clyde-hook.sh` that throws them away, writing only `session_id`, `pid`, `cwd`, `event` and `timestamp` — enough to raise a badge, not enough to answer. The change is on Clyde's side and smaller than this spec first assumed. The panel shows the tool and its input untruncated: a shortened command invites approving something the user did not read, which is the one thing this feature must not encourage. Long commands scroll within the row.

**The answer goes back.** The `PermissionRequest` payload carries no `tool_use_id` — checked against a real one — so the hook mints a request id itself, names the request file with it, and Clyde answers to that name. The waiting hook polls for the answer within the window, reads it, deletes it, and prints the decision. Polling a file with a bounded wait is what the rest of this architecture already does; a socket would be cleaner and introduces a daemon.

**Nothing else can answer.** The decision file is bound to one request id, is only honoured inside that request's window, and is deleted on read — so a decision cannot be planted ahead of time or replayed. This is the part of the phase that deserves the most care: today anything that can write to `~/.clyde/` can lie to the panel about what it shows; afterwards it can approve the execution of a tool.

**Every failure ends in `ask`.** Clyde not running, a malformed or unreadable file, a half-written decision, the window expiring — all of them fall through to the terminal's own prompt. The hook still never exits non-zero and still never blocks past its window.

## On screen

The request appears on the session's row: the tool name, the command, and two buttons. It clears itself when the window closes, whichever way the answer came — a request answered in the terminal must not leave a dead prompt in the panel.

## Rollout

Off by default, behind a setting, until it has run on more than one machine. Today's v0.8.0 panel regression shipped a defect that could not be reproduced on the development machine at all; a feature that sits in the critical path of every session gets a stronger version of that caution.

## How this is verified

Unit tests cover the decision file's lifetime and every fallback-to-`ask` path. The hook gets its usual smoke test with a fake payload.

Neither proves the thing that matters. The real check is a live session: a permission request answered from the panel, one answered in the terminal while the panel is showing it, one left to time out, and one with Clyde killed mid-window. Those become a `scripts/dev/scenarios.sh` scenario, because every real bug in this project so far was found by putting the app in a state and looking at it.

The measurement that must exist before release: the added latency on tool calls that are **not** permission-gated. If the spike lands on option 2 or 3, that number is the feature's real cost and it belongs in CI, not in someone's memory.

## Recorded from the spike, for whoever implements this

`permission_suggestions` arrives with each request — Claude's own proposals, such as adding the working directory or switching to `acceptEdits`, each scoped to the session. Out of scope here, but it is the obvious second act once one-click answering works.

One detail left unexplained: a session launched with `--permission-mode manual` reported `permission_mode: "default"` in the payload. It did not affect the result — the request fired and the decision was honoured — but anything that keys behaviour on that field should confirm what it means first.
