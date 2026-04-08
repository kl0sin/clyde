# Hook integration smoke test

Manual end-to-end checklist for the Clyde ↔ Claude Code hook pipeline.
Run this before any release-cut and after any change that touches
`clyde-hook.sh`, `HookInstaller`, `ProcessMonitor`, or `AppPaths`.

The unit tests cover the static contracts (matcher shape, migration,
identity check, busy-marker survival). They cannot cover what only a
real Claude session can prove: that the hook actually fires for live
events, that markers reach the UI, and that nothing in the install
flow breaks user-side state.

## Pre-flight

Before any scenario:

1. Build a fresh binary: `swift build`.
2. Open a terminal you can spare for monitoring:
   ```sh
   tail -F ~/.clyde/logs/hook.log
   ```
3. Open a second terminal for state inspection:
   ```sh
   watch -n 1 'ls -la ~/.clyde/state/'
   ```
4. Have an extra terminal ready to run `swift run Clyde`.

You should see hook events stream into `hook.log` and `-busy` /
`-info` files appear and disappear in `state/` as you exercise
each scenario.

---

## Scenario 1 — Fresh install from zero

**Goal:** auto-install + first-run integration works end to end.

**Setup:**
```sh
# Wipe any existing Clyde state. DESTRUCTIVE — only do this on a
# dev machine where you don't mind re-installing.
rm -f ~/.claude/hooks/clyde-hook.sh ~/.claude/hooks/clyde-notify.sh
python3 -c "
import json, os
p = os.path.expanduser('~/.claude/settings.json')
if os.path.exists(p):
    d = json.load(open(p))
    h = d.get('hooks', {})
    for ev in list(h.keys()):
        h[ev] = [e for e in h[ev] if not any('clyde' in (x.get('command','')) for x in e.get('hooks',[]))]
        if not h[ev]: del h[ev]
    json.dump(d, open(p, 'w'), indent=2)
"
rm -rf ~/.clyde/state ~/.clyde/events
```

**Steps:**
1. `swift run Clyde`
2. Open a fresh `claude` session in another terminal.
3. Send a prompt that takes more than a couple seconds (e.g. "list
   the files in this project and summarize what each does").

**Expect:**
- `~/.claude/hooks/clyde-hook.sh` exists with `clyde-hook-version: 13`
  or later.
- `~/.claude/settings.json` contains Clyde entries for every event in
  `HookInstaller.registeredHookEvents`. `PreToolUse` and
  `PostToolUseFailure` entries have `"matcher": ""`.
- `hook.log` shows `event=SessionStart`, `event=UserPromptSubmit`,
  one or more `event=PreToolUse`, and finally `event=Stop`.
- `state/` shows a `<sid>-info` file the whole time the session is
  alive, and a `<sid>-busy` file from `UserPromptSubmit` until
  `Stop`.
- Clyde UI shows the session as "Working" continuously while Claude
  is processing, returning to idle after the response.
- No "hook error" lines in the Claude TUI output.

---

## Scenario 2 — Legacy `clyde-notify.sh` migration

**Goal:** users upgrading from a pre-v13 install get auto-migrated
without manual intervention.

**Setup:**
```sh
# Simulate the legacy install state.
rm -f ~/.claude/hooks/clyde-hook.sh
cp Clyde/Resources/clyde-hook.sh ~/.claude/hooks/clyde-notify.sh
chmod +x ~/.claude/hooks/clyde-notify.sh
# Point settings.json at the legacy path.
python3 -c "
import json, os
p = os.path.expanduser('~/.claude/settings.json')
d = json.load(open(p)) if os.path.exists(p) else {}
h = d.setdefault('hooks', {})
legacy = os.path.expanduser('~/.claude/hooks/clyde-notify.sh')
for ev in ['SessionStart','UserPromptSubmit','Stop']:
    h.setdefault(ev, []).append({'hooks': [{'type':'command','command': legacy}]})
json.dump(d, open(p, 'w'), indent=2)
"
```

**Steps:**
1. `swift run Clyde`
2. Watch the hooks dir: `ls ~/.claude/hooks/` before and after launch.

**Expect:**
- `clyde-notify.sh` is gone after Clyde starts.
- `clyde-hook.sh` is in its place.
- `settings.json` no longer references `clyde-notify.sh`. Every Clyde
  entry now points at `clyde-hook.sh`.
- No duplicate Clyde entries in any event array.
- Subsequent `swift run Clyde` cycles do not re-trigger migration
  (idempotent).

---

## Scenario 3 — External rewriter strips Clyde entries

**Goal:** when another tool (claude-visual, etc.) rewrites
`settings.json` and drops Clyde's entries, the settings.json watcher
re-installs them within ~300 ms.

**Setup:**
- Clyde must already be installed (run Scenario 1 first if needed).
- `swift run Clyde` running.

**Steps:**
1. In a terminal, dump the current Clyde entries:
   ```sh
   python3 -c "import json, os; d=json.load(open(os.path.expanduser('~/.claude/settings.json'))); print(len([e for ev in d['hooks'].values() for e in ev if any('clyde' in (x.get('command','')) for x in e.get('hooks',[]))]))"
   ```
   Should print the number of Clyde entries (8 at the time of
   writing).
2. Strip all Clyde entries:
   ```sh
   python3 -c "
   import json, os
   p = os.path.expanduser('~/.claude/settings.json')
   d = json.load(open(p))
   for ev in list(d['hooks'].keys()):
       d['hooks'][ev] = [e for e in d['hooks'][ev] if not any('clyde' in (x.get('command','')) for x in e.get('hooks',[]))]
       if not d['hooks'][ev]: del d['hooks'][ev]
   json.dump(d, open(p, 'w'), indent=2)
   "
   ```
3. Wait one second. Re-run the count from step 1.

**Expect:**
- Within ~1 second the count is back to its original value.
- `Clyde` log line `Auto-installed/repaired Claude hook` appears in
  `Console.app` under the `com.clyde` subsystem.
- No infinite loop: `lastSelfWriteAt` echo suppression should keep
  the watcher from re-firing on its own write.

---

## Scenario 4 — Long prompt with permission request

**Goal:** the busy marker stays through the entire Permission
request → user approval → tool execution cycle, and the row in
Clyde shows "Needs Input" then "Working" then idle.

**Setup:**
- Clyde running and healthy.
- A fresh `claude` session.

**Steps:**
1. Send a prompt that triggers a Bash command Claude has not seen
   before, e.g. `run \`uname -a\``.
2. When Claude asks for permission, watch the Clyde widget — it
   should switch from Working to Needs Input.
3. Approve the permission.
4. Watch through to completion.

**Expect:**
- `hook.log` shows: `UserPromptSubmit`, one or more `PreToolUse`,
  `PermissionRequest`, then more `PreToolUse` after approval,
  finally `Stop`.
- `state/` shows the `-busy` marker for the full duration —
  including across the permission prompt. It must NOT briefly
  disappear.
- `events/<sid>.json` appears at `PermissionRequest` and disappears
  at the next `PreToolUse`.
- Clyde UI: Working → Needs Input → Working → idle. No flicker
  back to idle while Claude is mid-tool.

---

## Scenario 5 — `claude --resume`

**Goal:** resuming an existing session keeps the same `session_id`
and Clyde recognises it without producing a duplicate row.

**Setup:**
- One `claude` session, send a prompt, let it finish, exit.
- Note the session_id from the `hook.log` lines for that run.

**Steps:**
1. `claude --resume` and pick the session you just exited.
2. Send another prompt.
3. Watch `state/` and `hook.log`.

**Expect:**
- A new `SessionStart` event fires with the SAME `sid` as before.
- No new `<other-sid>-info` file appears.
- Clyde does NOT show two rows for the resumed session.
- Working → idle cycle behaves like a fresh session.

---

## Scenario 6 — Stop hook noise from sibling tools

**Goal:** confirm that "Stop hook error: Failed with non-blocking
status code" reports in the Claude TUI come from OTHER tools' hooks
(if any), not from `clyde-hook.sh`. Our script must always exit 0.

**Steps:**
1. `swift run Clyde`, fresh `claude` session.
2. Send a few prompts that trigger Stop events.
3. After each, check the Claude TUI for "Stop hook error" lines.

**Expect:**
- If a "Stop hook error" appears, `tail ~/.clyde/logs/hook.log`
  immediately after — the latest line for `event=Stop` should show
  no error context (no `WARN` line, no `ERR trap` log entry). If
  our log is clean, the error came from a sibling hook.
- If a `WARN` or `ERR trap` line IS present in our log, that is a
  bug in `clyde-hook.sh` and must be fixed before release.

---

## Cleanup

After running scenarios that mutate `~/.claude/`, restore your normal
state by re-running `swift run Clyde` once — it will auto-install
the canonical hook on launch.

If a scenario left orphan files in `state/` or `events/` (e.g. from a
crashed run), the safest reset is:

```sh
rm -rf ~/.clyde/state ~/.clyde/events
```

Clyde recreates them on next launch.
