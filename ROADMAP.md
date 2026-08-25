# Clyde Roadmap

Post-v0.2.0 work for Clyde, the macOS menu bar app that watches every Claude Code session in real time.

Phases follow Clyde's release rhythm. Detail behind each task lives in [`docs/roadmap.md`](docs/roadmap.md); the historical record of what shipped is in [`CHANGELOG.md`](CHANGELOG.md) and [`docs/pre-launch-checklist.md`](docs/pre-launch-checklist.md).

## Phase: v0.2.1 — Sign and ship properly

First signed + notarized release. Single goal: eliminate the "unidentified developer" Gatekeeper friction that v0.1.0 / v0.2.0 still ship with. No new product features unless a critical bug demands one.

- [x] Apple Developer Program membership + Developer ID cert ready !hi
- [x] Wire up GitHub Secrets for the release pipeline (cert, password, Apple ID, Sparkle key) !hi
- [x] First signed + notarized release cut !hi
- [x] Gatekeeper verification on a clean Mac !hi
- [x] Activate Sparkle appcast — verify v0.2.0 sees an update !hi
- [x] Resolve "Commit appcast back to main" vs branch-protection ruleset !md
- [x] Fix Sparkle update dialog showing only fallback copy — `update-appcast.sh` regex didn't match Keep-a-Changelog `## [x.y.z]` heading format, so v0.2.1 shipped with "See the changelog for details." instead of real notes !hi
- [x] Publish Homebrew cask to `kl0sin/homebrew-tap` !md
- [x] Update CHANGELOG with signed-release entry, promote resolved Known Limitations !lo
- [x] Refresh landing page to drop the "unsigned prerelease" warning !lo

## Phase: v0.2.x — Hook pipeline followups + UX polish

Items surfaced by the 0.1.0 / 0.2.0 smoke tests and deferred to avoid scope creep.

- [x] Render Sparkle release notes as HTML — convert CHANGELOG markdown (bullets, bold, links) to HTML in `update-appcast.sh` so the update dialog formats properly instead of showing raw `**bold**` / `- ` syntax !md #release
- [x] Document the `PermissionRequest → deny` hook trace in `clyde-hook.sh` + smoke-test doc !md #hooks
- [x] Fix phantom `-info` files from recycled PIDs in `discoverPIDs` !md #hooks
- [x] Investigate `claude --resume` firing two `SessionStart` events ~1 minute apart — root cause: the second event is Claude Code's auto-compact restart signal (`source=compact`), fired alongside `PostCompact`, not a `--resume` bug. Hook now records `source=…` on `SessionStart` lines (`clyde-hook` v16) so future investigations don't need to correlate with `PreCompact`/`PostCompact` !lo #hooks
- [x] Surface auto-compact as its own Activity timeline entry — `ActivityLog.Snapshot` now tracks `lastSource` and emits `.sessionCompacted` when the SessionStart `source` flips to `compact`/`clear` in the same PID. Hook source is also folded into the reconcile fingerprint so the in-PID transition isn't short-circuited away !lo #ux
- [x] Document keyboard shortcuts (⌃⌘C and friends) in README + Settings !lo #ux
- [x] Bump GitHub Actions to Node-24-compatible versions — `actions/checkout` v4→v6, `softprops/action-gh-release` v2→v3, `actions/configure-pages` v5→v6, `actions/upload-pages-artifact` v3→v5, `actions/deploy-pages` v4→v5. All drop-in major bumps; the only behavioural change in each release is the runtime move from Node 20 to Node 24 !lo #release
- [x] Validate the v0.2.2 cask-version fix on the next release — verified end-to-end on the v0.2.3 release (2026-04-29): `Casks/clyde.rb` in `kl0sin/homebrew-tap` carries `version "0.2.3"` (no placeholder), `site/appcast.xml` carries `<sparkle:shortVersionString>0.2.3</sparkle:shortVersionString>`, and the DMG enclosure URL resolves to `…/v0.2.3/Clyde-0.2.3.dmg` !md #release

## Phase: v0.3.0 — Richer session telemetry

Push Clyde from "monitor" toward "feed of what Claude is actually doing" by harvesting payload fields the hook bus already delivers but Clyde currently throws away. All work is on the existing local hook pipeline — no new IPC surface.

- [x] Surface current tool + duration in the panel — `clyde-hook` v17 writes `state/<sid>-tool` on `PreToolUse` (whitelisted summary per built-in tool: `file_path` basename for Edit/Write/Read/MultiEdit/NotebookEdit, host for WebFetch, first 40 chars of command for Bash, pattern for Glob/Grep, `subagent_type` for Task, query for WebSearch; empty summary for TodoWrite/MCP/unknown), and clears it on `PostToolUse`/`PostToolUseFailure`/`Stop`/`SessionEnd`. `ProcessMonitor.refreshHookTools` mirrors the existing `-subagent` plumbing one-for-one; `SessionRow`'s second line is now a `ZStack` that slides between project path and `<Tool> · <summary> · <Ns>` (spring 0.28 / 0.85, fixed-height clipped) with the duration tick driven by `TimelineView(.periodic)` !md #hooks #ux
- [x] Subscribe to `TaskCreated` hook event — `clyde-hook` v18 maintains `state/<sid>-plan` (`task_count` + `done_count`) via read-modify-write on `TaskCreated` and `TaskCompleted`, cleared on `SessionEnd`. `SessionRow` shows an inline `PlanBadge` (purple while in progress, green ✓ on completion) with a 24×3 px progress bar; cross-turn persistent (no clear on `Stop`). Manual escape hatch via context-menu "Reset session state", which now clears every hook marker (`-info`/`-busy`/`-error`/`-subagent`/`-tool`/`-plan`) plus any pending event !lo #hooks #ux

## Phase: v0.4.x — UI polish + sandbox awareness

Bug-fix and polish pass after v0.4.0, plus first-class integration with [cleat](https://github.com/cleatdev/cleat) so Claude Code sessions running inside its Docker sandbox surface in Clyde's panel like native ones.

- [x] Track cleat-sandboxed Claude sessions — `clyde-hook` v25 walks PPID for the topmost cleat host process and matches its lsof cwd against running cleat containers' `/workspace` mount Source to recover the canonical container name. `-info` carries new `runtime`/`container` fields; `ProcessMonitor` relaxes its `argv[0]==claude` identity check for cleat-tagged PIDs (the anchor is the cleat shell PID, not the in-VM container init which lives in the Docker Desktop VM's PID namespace). `SessionRow` renders a cyan "cleat" capsule next to the project name. Requires `cleat config --enable hooks` so cleat's host hook bridge forwards events !md #hooks #ux
- [x] Stop plan + cleat badges from getting clipped on narrow rows — `fixedSize` on both capsules so the project name takes the ellipsis instead !lo #ux
- [x] Healthcheck advisory when `cleat` is on PATH but its `hooks` capability is disabled — `CleatProbe` reads `~/.config/cleat/config` (cleat stores enabled caps as a `[caps]` section, one per line) and reports its `hooks` cap status; `HookInstaller.healthCheck()` returns a new `.cleatHooksCapDisabled` issue (non-auto-repairable — Clyde can't run `cleat config --enable hooks` for the user, only the banner can) so the existing banner pipeline picks it up. Surfaces only when Clyde's own install is otherwise healthy, so the user fixes the actual problem first !md #ux

## Phase: v0.7.0 — Agent teams + faithful subagent lifecycle

Clyde's hook coverage stopped growing at v0.4.0 while Claude Code kept shipping events. Clyde subscribes to 20 of the 31 documented hook events, and the gap sits exactly where Claude Code got more autonomous: agent teams, batched tool calls, slash-command expansion. This phase closes that gap and fixes the one place where the current model is provably wrong — subagent lifecycle keyed on the dispatching tool call instead of on the agent itself.

- [x] Subagent lifecycle keyed on `agent_id` — `clyde-hook` v28: `PreToolUse(Agent)` now writes `-agents/pending-<tool_use_id>.json`, `SubagentStart` adopts the oldest pending entry of matching `agent_type` and re-keys it under `agent_id`, `SubagentStop` owns teardown, and `PostToolUse` sweeps only entries nothing ever claimed. Correlation is by type because the events share no identifier — verified on a live session, where `SubagentStart`/`SubagentStop` carry `agent_id` + `agent_type` but no `tool_use_id`, and only `PreToolUse` carries the description. That session also measured the bug: `PostToolUse(Agent)` fired 5s before `SubagentStop`. The merge is symmetric and lock-guarded because live testing showed Claude fires the two events as concurrent processes with no ordering guarantee — the `PreToolUse` hook is ~100ms slower (it probes cleat and shells out to lsof), so `SubagentStart` usually wins and a one-directional claim lost the agent entirely. An interrupt also sweeps the whole `-agents/` dir, since an interrupted agent never emits `SubagentStop`. `ProcessMonitor.refreshHookAgents` reads `agent_id ?? tool_use_id`. Verified live: three concurrent same-type agents tracked 0→1→2→3 and torn down 3→2→1→0, no leftovers !hi #hooks
- [ ] Retire the legacy `-subagent` marker and `ProcessMonitor.refreshHookSubagents` — dead weight once every session runs on a v28 hook; keep one release of overlap first !lo #hooks
- [x] Subscribe to `TeammateIdle` — `clyde-hook` v29 flags an existing `-agents/<agent_id>.json` as `idle` (never creates one: a teammate we never saw start must not materialise a row), `ProcessMonitor` carries it into `ActiveSubagent.isIdle`, and `SessionRow` settles the sprite, stops the duration tick and drops the accent to grey. Deliberately **not** wired to the attention badge, contrary to this item's original phrasing — v0.5.1 mapped an ambiguous attention-sounding event onto that badge on identical reasoning and v0.5.2 had to revert it a day later. Promoting it is one line; un-shipping a false positive is a hotfix. Not verifiable on this machine — no agent teams available, confirmed by a payload dump with `Stop` as positive control (2 captured, `TeammateIdle` 0), so the firing frequency and payload remain unconfirmed !hi #hooks #ux
- [ ] Confirm `TeammateIdle` against a real agent-teams session — payload fields and firing frequency; decide then whether idle deserves promotion to the attention badge !md #hooks #qa
- [x] Running slash command shown as an amber `/name` badge — `clyde-hook` v31 writes `state/<sid>-command` on `UserPromptExpansion`, cleared by `Stop`/`SessionEnd`; `ProcessMonitor` carries it to `Session.activeCommand`. **Payload unverified against a live session**: the event fires only when a human types a slash command, so the implementation follows the documented `command_name` field. A payload dump with `Stop` as positive control captured 0 of these while capturing `Stop` normally !md #hooks #ux
- [x] Parallel tool calls are honest — `clyde-hook` v30 replaces the single-slot `-tool` marker with `state/<sid>-tools/<tool_use_id>.json`, one slot per in-flight call, cleared individually by `PostToolUse`/`PostToolUseFailure`, swept wholesale by `PostToolBatch` and by `Stop`/`SessionEnd`. `SessionRow` renders `N tools · <dur>` for N≥2 and the single label otherwise; `ProcessMonitor` keeps reading the legacy `-tool` file for one release. Real payload correction: `PostToolBatch` carries **no** `batch_id` despite the docs — `tool_calls` is a list of `{tool_name, tool_use_id, tool_input, tool_response}` and correlation is per `tool_use_id`. Verified live: two concurrent slots observed with distinct ids and clean teardown !md #hooks #ux
- [x] One-line reply preview — `Stop` writes `state/<sid>-lastmsg` (newlines collapsed, truncated to 80 chars), `UserPromptSubmit` clears it as stale and `SessionEnd` sweeps it. `SessionRow` shows `› <reply>` on the second line for idle sessions, keeping the tool line for busy ones and the project path as fallback. Chosen over `MessageDisplay` deliberately: that would hand us every message in full, which is noise on the row and a privacy question on disk !lo #hooks #ux
- [x] Worktree badge — `clyde-hook` v32 writes `state/<sid>-worktree` (name + path) on `WorktreeCreate`, cleared by `WorktreeRemove`/`SessionEnd`. `ProcessMonitor` only applies the badge when the session's cwd is actually inside the recorded path, so a session that left the worktree drops it. **Payload unverified against a live session**: firing the event means entering a worktree, and `EnterWorktree` forbids that without an explicit user or CLAUDE.md instruction !lo #hooks #ux
- [x] Tool-summary whitelist extended to `Skill` (skill name), `Workflow` (`name`, falling back to the `scriptPath` basename) and `Artifact` (`title`, falling back to the published file's basename) — all three previously rendered as a bare tool name. Verified live: a real `Skill` call produced `summary='superpowers:verification-before-completion'` in the `-tool` marker !lo #hooks

## Phase: v0.7.x — Stabilization

The stability work that does *not* need special hardware, split out from the sprint above so features never block on a Ventura VM. Sibling phase to `Testing backlog`, which keeps the hardware- and wall-time-gated items.

- [ ] Regression coverage per hook event — `HookScriptTests` exercises a fraction of the 20 handled events; every event that writes or clears a state file deserves a case !hi #qa #hooks
- [ ] First `ActivityLog` test coverage — mirror the integration style in `ProcessMonitorTests` (real instance + temp `stateDir`, driven by writing marker files) !md #qa
- [ ] Audit zombie / GC paths in `state/<sid>-agents/` — the 30-minute defensive sweep predates the `agent_id` rework and needs revisiting alongside it !md #qa #hooks
- [ ] Error-path audit of `HookInstaller` — healthcheck, repair, and version-bump branches are the least-exercised code in the app and the most user-visible when they misfire !md #qa

## Phase: v0.8.0 — Session stats & review

Clyde answers "what is Claude doing right now" well. It answers "what did Claude do today" not at all, even though `ActivityLog` already records most of the raw material. A local review surface is the natural next step and the most screenshot-friendly feature on this roadmap.

- [ ] Daily / weekly session review — time spent working, turns taken, most-used tools, how often a session sat waiting on you !hi #ux
- [ ] Per-project breakdown, so multi-repo days are legible !md #ux
- [ ] Decide the retention window and make it configurable — stats need history, and history is the one thing Clyde has so far avoided keeping !md #ux
- [ ] Stays local by construction — no telemetry, no accounts, no network, matching the privacy-first promise in the README !hi #ux

## Phase: v0.9.0 — Panel actions (two-way channel)

The biggest draw for new users and the biggest architectural jump on this roadmap: approving a permission request or sending a prompt straight from Clyde, without switching to the terminal. Clyde's hook bus is deliberately one-way and advisory today — every design note in `clyde-hook.sh` depends on that. Reversing it touches the trust model, not just the plumbing, so this phase gets its own spec before any code.

- [ ] Write the design spec first — brainstorming → `docs/superpowers/specs/` → writing-plans. Do not start with the transport !hi
- [ ] Map the landmines up front: hooks must never block or fail noisily, `PreToolUse` decisions are time-boxed by Claude's hook timeout, and any inbound channel is a new local attack surface !hi
- [ ] Decide the mechanism — `PreToolUse` `permissionDecision` returned from the hook vs. an out-of-band channel — before committing to a UI !hi

## Phase: v0.3.0+ — UX polish, content & reach

Backlog. Pick when there's time or when community interest bumps priority.

- [x] Coachmark first-run tour — four anchored popovers (session row + tool/plan line + snooze + collapse with ⌃⌘C hotkey discovery) using SwiftUI's native `.popover`. Empty-state branch handles "panel opened before any session exists" with a three-step degraded tour. Migration suppresses the tour for users upgrading from a Clyde version that didn't have it !md #ux
- [x] Accessibility pass — every interactive surface has a VoiceOver label, traits, hints, and (where relevant) values; the pixel-art mascot and inner indicators are marked decorative; reduce-motion freezes the sprite, disables auto-running pulses, and swaps slide transitions for opacity crossfades while leaving drag-and-drop and color crossfades alone !md #ux
- [ ] Copy proofread by a second pair of eyes !lo #ux
- [x] "Replay welcome tour" button in Settings → General. Clears the persisted flag and either fires the tour immediately (panel open) or queues it for the next expand (panel collapsed) with an inline confirmation label !lo #ux
- [x] Launch at login — `LoginItemService` wraps `SMAppService.mainApp` (macOS 13+ API, no deprecated `SMLoginItemSetEnabled` fallback; system owns the state, no UserDefaults mirror) behind an injectable `LoginItemBackend` protocol for tests. Settings → General gains a "Startup" section: optimistic toggle that reconciles back to the system truth on registration failure (e.g. unsigned dev builds) with an inline error, plus an orange "Approval needed" banner with an "Open Login Items" shortcut when SMAppService reports `.requiresApproval` — that state reads as *off* through `isEnabled` since the toggle wouldn't actually launch Clyde yet. State refreshes `onAppear` so changes made directly in System Settings are picked up !md #ux
- [x] Parallel subagents in the panel — `clyde-hook` v20 writes `state/<sid>-agents/<tool_use_id>.json` on every `PreToolUse(Task)` and clears it on the matching `PostToolUse(Task)` / failure; `ProcessMonitor.refreshHookAgents` mirrors the existing `-tool` plumbing. `SessionRow` flips the second line to `<N> agents · <dur>` for N≥2 and renders a two-lines-per-agent block (type · duration, then summary) underneath, sorted oldest-first with a 3-visible cap and tap-to-expand `+N more` label. Defensive 30-min GC drops zombie rows; legacy `-subagent` fallback keeps v0.2.x sessions visible until next `claude` restart. !md #hooks #ux
- [ ] Short demo video (30-60s) showing busy / ready / attention flow !md
- [ ] Press kit folder — logos, screenshots, fact sheet !lo
- [ ] Launch post on Product Hunt and r/ClaudeAI — hold until the v0.8.0 review surface exists, so the post has a screenshot worth clicking !md
- [ ] Refresh the landing page around agent teams and session stats — it still sells the v0.2.x feature set !md #ux
- [ ] Opt-in crash reporting (Sentry / KSCrash / MetricKit), off by default !lo
- [ ] Opt-in anonymous usage analytics, off by default !lo
- [ ] App Store yes/no decision (likely no — sandbox + StoreKit cost) !lo
- [ ] Trademark check on the name "Clyde" in US/EU databases !lo

## Phase: Testing backlog

Items that need real hardware or long wall time to verify.

- [ ] Test on minimum supported macOS version (13.0 Ventura) !md #qa
- [ ] Test on Intel Mac (universal binary) !md #qa
- [ ] Test with multiple Claude sessions across multiple terminals simultaneously !md #qa
- [ ] Test all three terminal adapters (Terminal.app, Warp, Ghostty) end-to-end !md #qa
- [ ] Test on a fresh user account (no `~/.claude`, no `~/.clyde`) !md #qa
- [ ] 24h memory leak / long-running stress test !lo #qa
