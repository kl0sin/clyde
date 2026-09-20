# Automated sessions, the follow-ups — design

**Status:** agreed in conversation on 2026-09-20; ready to plan.

**Phase:** v0.10.0

## What this is

The automated-sessions work (`docs/superpowers/specs/2026-09-16-automated-sessions-design.md`) shipped with three items parked in ROADMAP. This picks all three up.

## 1. The Activity trail on a toggle

**Problem.** `ActivityLog` diffs the list `ProcessMonitor` publishes. Flipping "Show automated sessions" changes that list without any session starting or stopping, so the trail records `sessionEnded` for every hidden session on the way off and `sessionStarted` on the way on.

**Design.** The log keeps a snapshot for every *tracked* live session, not only the published ones, and emits events only for sessions that are published. A hidden session is seeded silently and updated silently; when it later becomes visible it already has a snapshot, so nothing says "started"; when it becomes hidden it is still tracked, so nothing says "ended". A session is "gone" only when it leaves `trackedSessions`. Hidden sessions therefore never appear in the trail, and the toggle is invisible to it. Shown sessions behave exactly as ordinary ones.

## 2. The cleat branch of the hook has no test

**Problem.** `detect_headless` skips the stdin rule when `CLEAT_RUNTIME` is set, and that branch has no coverage because the hook decides it runs under cleat by walking the parent chain for a `cleat` process and asking Docker — nothing a test can stage.

**Design.** A test seam beside the existing `CLYDE_HOOK_STDIN`: when `CLYDE_HOOK_CLEAT` is set, the hook takes it as the container name, sets `CLEAT_RUNTIME=cleat`, and resolves `CLAUDE_PID` with the ordinary parent walk (the tests' fake `claude`). Production never sets it. Two tests: cleat plus a piped stdin is not headless; cleat plus an `sdk-*` entrypoint is. The hook version bumps to 47.

## 3. The review window counts automated sessions as work

**Problem.** The history spool records every session, so the review window's working time, turns, sessions and project rows include the forty sessions a test suite ran.

**Design.** The spool line carries `"headless": true` on any event where the hook detected it (SessionStart and the backfills — the same places the `-info` flag comes from). `HistoryStore` keeps a table `automated_sessions(session_id)` filled on ingest, and a view `human_events` over `events` excluding those sessions. `HistoryStats` reads `human_events` everywhere it read `events`; `HistoryStore.eventCount()` and friends keep reading `events`, because Settings › History reports what is stored, not what is counted. The review window therefore excludes automated sessions by default, with no toggle: the review is about the user's own work, and the "Show automated sessions" switch is about the live panel. Existing databases get the table and the view on open; rows ingested before this change have no flag and stay counted, which is honest about what was recorded.

## Verification

Unit tests: an `ActivityLogTests` case that toggles the monitor's closure with a hidden session live and asserts no events either way, and that the same session shown from the start behaves as before; two `HookScriptTests` cases for the cleat seam and one asserting the spool line carries `headless`; `HistoryStoreTests` parses the flag and ingests the session into `automated_sessions`; `HistoryStatsTests` asserts an automated session's turn adds no working time and no session count while a human one does, and that a pre-flag database opens and migrates.

Live: run `scripts/dev/scenarios.sh automated-sessions`, then flip the switch twice with the panel open — the Activity trail must not change — and open the review window: the three headless sessions must not be in today's numbers.
