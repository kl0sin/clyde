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
