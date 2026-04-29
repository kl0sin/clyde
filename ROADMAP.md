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
- [ ] Coachmarks / "how to use" tooltip on first panel expand !md #ux
- [ ] Accessibility pass — VoiceOver labels on all controls !md #ux
- [x] Document keyboard shortcuts (⌃⌘C and friends) in README + Settings !lo #ux
- [ ] Copy proofread by a second pair of eyes !lo #ux
- [x] Bump GitHub Actions to Node-24-compatible versions — `actions/checkout` v4→v6, `softprops/action-gh-release` v2→v3, `actions/configure-pages` v5→v6, `actions/upload-pages-artifact` v3→v5, `actions/deploy-pages` v4→v5. All drop-in major bumps; the only behavioural change in each release is the runtime move from Node 20 to Node 24 !lo #release
- [x] Validate the v0.2.2 cask-version fix on the next release — verified end-to-end on the v0.2.3 release (2026-04-29): `Casks/clyde.rb` in `kl0sin/homebrew-tap` carries `version "0.2.3"` (no placeholder), `site/appcast.xml` carries `<sparkle:shortVersionString>0.2.3</sparkle:shortVersionString>`, and the DMG enclosure URL resolves to `…/v0.2.3/Clyde-0.2.3.dmg` !md #release

## Phase: v0.3.0 — Richer session telemetry

Push Clyde from "monitor" toward "feed of what Claude is actually doing" by harvesting payload fields the hook bus already delivers but Clyde currently throws away. All work is on the existing local hook pipeline — no new IPC surface.

- [x] Surface current tool + duration in the panel — `clyde-hook` v17 writes `state/<sid>-tool` on `PreToolUse` (whitelisted summary per built-in tool: `file_path` basename for Edit/Write/Read/MultiEdit/NotebookEdit, host for WebFetch, first 40 chars of command for Bash, pattern for Glob/Grep, `subagent_type` for Task, query for WebSearch; empty summary for TodoWrite/MCP/unknown), and clears it on `PostToolUse`/`PostToolUseFailure`/`Stop`/`SessionEnd`. `ProcessMonitor.refreshHookTools` mirrors the existing `-subagent` plumbing one-for-one; `SessionRow`'s second line is now a `ZStack` that slides between project path and `<Tool> · <summary> · <Ns>` (spring 0.28 / 0.85, fixed-height clipped) with the duration tick driven by `TimelineView(.periodic)` !md #hooks #ux
- [ ] Subscribe to `TaskCreated` hook event — fires when Claude calls the `TaskCreate` (todo-list) tool. Add a case to `clyde-hook.sh`, persist a count to `state/<sid>-plan`, and surface a small "📋 planning N tasks" affordance so users know an extended plan-then-execute run is starting !lo #hooks #ux

## Phase: v0.3.0+ — Content & reach

Backlog. Pick when there's time or when community interest bumps priority.

- [ ] Short demo video (30-60s) showing busy / ready / attention flow !md
- [ ] Press kit folder — logos, screenshots, fact sheet !lo
- [ ] Opt-in crash reporting (Sentry / KSCrash / MetricKit), off by default !lo
- [ ] Opt-in anonymous usage analytics, off by default !lo
- [ ] App Store yes/no decision (likely no — sandbox + StoreKit cost) !lo
- [ ] Trademark check on the name "Clyde" in US/EU databases !lo
- [ ] Coachmark re-trigger from Settings ("Replay welcome tour") !lo

## Phase: Testing backlog

Items that need real hardware or long wall time to verify.

- [ ] Test on minimum supported macOS version (13.0 Ventura) !md #qa
- [ ] Test on Intel Mac (universal binary) !md #qa
- [ ] Test with multiple Claude sessions across multiple terminals simultaneously !md #qa
- [ ] Test all three terminal adapters (Terminal.app, Warp, Ghostty) end-to-end !md #qa
- [ ] Test on a fresh user account (no `~/.claude`, no `~/.clyde`) !md #qa
- [ ] 24h memory leak / long-running stress test !lo #qa
