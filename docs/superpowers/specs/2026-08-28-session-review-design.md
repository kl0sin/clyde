# Clyde — Session Review Design Spec

## Overview

Clyde answers "what is Claude doing right now" well and "what did Claude do today" not at all. Every signal needed for the second question already flows through the hook bus and is then thrown away: markers are deleted the moment a tool call finishes, and `ActivityLog` keeps fifty events in memory that vanish on relaunch. This spec adds the first durable store Clyde has ever had, plus a review window that reads it.

**Target:** macOS 13 Ventura+
**Stack:** Swift, SwiftUI, system `libsqlite3`
**New dependencies:** none

---

## What the feature is for

Three questions came up as equally valuable, so the store serves all three rather than one deeply:

- **Where did my day go** — time and turns split across projects.
- **How much did we wait on each other** — how long sessions sat idle waiting on the human, how often a permission prompt blocked one.
- **What did Claude actually do** — which tools ran, which plans completed, which subagents were dispatched.

They differ only in the view that reads the data. All three are satisfied by one event stream.

## What gets stored

Events, plus exactly the summaries the panel already renders: tool name and its 40-character summary, plan counters, subagent types, the slash command, the worktree name, the project path. **No conversation content.** The `MessageDisplay` hook was rejected in v0.7.0 for putting message bodies on disk, and that decision stands — the `-lastmsg` preview is a live marker, not history.

The rule is that persistence changes the lifetime of what Clyde already shows on screen, never the category. Nothing becomes visible to the store that is not already visible in the panel.

## Retention

None. History grows until the user clears it.

This was a deliberate choice over a rolling window plus daily rollups. The consequence is accepted and has to be designed for: measured on real usage, a heavy day produces ~1700 events and a normal one ~300, which is roughly 200 KB/day at peak, so a year of heavy use lands in the tens of megabytes. Two things follow. The store must be indexed rather than a scanned flat file, because a day view cannot re-read a year of events on every open. And Settings must show the database size, the event count and the oldest retained date next to a "Clear history" button — manual cleanup that the user cannot see the need for is not cleanup.

## Architecture

The hook produces, the app consumes. This is the split that already works for state markers, made durable.

```
clyde-hook.sh ──append──▶ ~/.clyde/history/spool.jsonl
                                    │
                          rename + drain (Clyde)
                                    ▼
                        ~/.clyde/history/history.sqlite ──▶ Review window
```

### Why not the alternatives

**App writes what it observes.** Rejected because it loses data. Clyde sees the world through a 3-second poll, so a short turn can fall between samples, and anything that happens while Clyde is closed is gone forever. A history with holes wherever the app was not running undermines the feature it is meant to support.

**Hook writes straight to the database.** Rejected because it puts growing requirements inside a shell script whose one hard rule is that it must never block and never fail — a hook that stalls or exits non-zero raises an error in the user's session on every turn. Appending a line is the most that belongs there.

## Components

### Spool (hook side)

`clyde-hook.sh` appends one JSON line per event to `~/.clyde/history/spool.jsonl`. This is the same move it already makes for `hook.log`: an `O_APPEND` write below the buffer size is atomic, so concurrent hooks cannot interleave, and a failed write is ignored so the user's session never notices.

Fields: timestamp, event name, `session_id`, `cwd`, and whatever that event already carries — tool name and summary, subagent type, plan counters, stop reason, command name, worktree name.

Hook script bumps to **v36**, with `HookInstaller.currentScriptVersion` raised to match.

### `HistoryStore` (app side)

Owns the SQLite database at `~/.clyde/history/history.sqlite`, opened through the system `libsqlite3` (`import SQLite3`). No new package dependency; this repo has exactly one (Sparkle) and the schema is two tables.

```sql
events(id INTEGER PRIMARY KEY, ts INTEGER, event TEXT, session_id TEXT,
       project TEXT, tool TEXT, summary TEXT, extra TEXT)
ingested_files(name TEXT PRIMARY KEY, ingested_at INTEGER)
```

Indexes on `ts` and on `(project, ts)`.

There are deliberately **no** derived tables for turns or daily totals. Working time, waiting time and turn counts are window queries over consecutive `UserPromptSubmit` → `Stop` pairs. Materialising them now would mean guessing today which questions get asked later, which is the exact failure the "store facts, not answers" choice was made to avoid.

### Ingestion

1. Rename `spool.jsonl` to `spool.<ts>.ingesting`. The rename is atomic, so the hook's next append transparently creates a fresh spool and never notices the handover. This avoids truncating a file another process is appending to — with parallel hooks, that race would fire sooner rather than later.
2. Parse the claimed file, inserting its events and its own filename into `ingested_files` **in one transaction**.
3. Delete the claimed file.

If Clyde dies between commit and unlink, the leftover file is recognised on the next launch and skipped. Without that, a crash inside this one window would double-insert, and the user would see a day with twice the working time and no way to guess why.

Ingestion runs at launch (leftover `.ingesting` files first, then the current spool), every ~30 seconds while running, and once on quit. Deliberately not on every poll tick: the review does not need second-level freshness, and writing to the database every 3 seconds is work with no reader.

### Review window

A dedicated `NSWindow`, opened from the menu bar menu and from the panel's Activity header — the same pattern Settings already uses, rather than a SwiftUI scene. Not inside the panel: that surface is 400×420 and built for glancing mid-task, while a review is something you sit down and read.

First release shows a day/week toggle, four tiles (working time, waiting time, turns, sessions), a per-project table (time, turns, most-used tools), and a filterable event list underneath that doubles as the audit trail.

## Failure modes

Every one of these ends the same way: the panel keeps working. Session tracking must never break because of a statistics feature.

| Failure | Behaviour |
|---|---|
| Database missing, unopenable or corrupt | `historyStore` is left `nil`; the review menu item silently does nothing and Settings shows "History tracking is unavailable." with no recovery action. Tracking is unaffected. A rebuild-from-scratch affordance is not built yet — see ROADMAP. |
| Malformed line in the spool | Skip that line, count the skips. A shell-written log can always be cut mid-line by a full disk. |
| Spool write fails in the hook | Ignored, exit 0, as with every other hook write. One lost event, not a broken session. |
| Disk full during insert | Transaction rolls back, the claimed file is left intact, retried on the next tick. |

Spool and database are created `0600`, matching the existing state markers. Local files only, no network — the README's privacy promise holds literally.

## Out of scope

Export, cross-device sync, automated retention, and anything beyond at most one simple hour-distribution chart. If a chart does land, the `dataviz` skill gets loaded before it is written: this would be the repo's first visualisation and the precedent should not be set by eyeballing it.

Existing `hook.log` history is **not** migrated. It is a text format without structured fields, so parsing it means maintaining a one-shot parser indefinitely for a one-time gain. History starts on the day the feature ships.

## Testing

**`HistoryStore` over a temporary directory:** ingest a synthetic spool, skip a malformed line, and — the important one — prove that a leftover `.ingesting` file does not double-insert after a restart.

**Queries over a hand-built event sequence:** working time, waiting time, turn counts, per-project grouping. Pure functions over the database, which is exactly where tests earn their keep.

**Hook coverage in `HookScriptTests`:** representative events append spool lines with the expected fields, and every existing state marker keeps behaving.

**Live verification before anything is called done:** a real session, confirming the spool grows, ingesting it, and reconciling the window's numbers against events counted by hand from `hook.log`. Four times in the week before this spec was written, a green suite coexisted with a dead feature; the store gets checked against reality, not against its own tests.
