# Roadmap detail

Companion to [`ROADMAP.md`](../ROADMAP.md). The top-level file is the checklist; this file holds the prose context for each open item — *why* it matters, *what* good looks like, and any landmines we've already mapped. Shipped items move to [`CHANGELOG.md`](../CHANGELOG.md); the historical pre-launch record lives in [`pre-launch-checklist.md`](pre-launch-checklist.md), and manual smoke scenarios in [`hook-smoke-test.md`](hook-smoke-test.md).

Phases below mirror `ROADMAP.md` one-for-one. Closed phases are kept as one-line pointers — go to the changelog for the user-facing recap.

---

## Phase: v0.2.1 — Sign and ship properly ✅

Shipped 2026-04-22. First signed + notarized release; Sparkle appcast activated; Homebrew cask published. Detail in `CHANGELOG.md` §0.2.1.

## Phase: v0.2.x — Hook pipeline followups + UX polish ✅

Shipped across v0.2.2 / v0.2.3 (2026-04-27 and 2026-04-29). Sparkle release-notes HTML rendering, recycled-PID phantom fix, auto-compact timeline entry, hook v16 source field, keyboard-shortcuts docs, GitHub Actions Node-24 bumps, cask-version regression validated end-to-end. Detail in `CHANGELOG.md` §0.2.2 and §0.2.3.

## Phase: v0.3.0 — Richer session telemetry ✅

Shipped 2026-04-29. Live tool indicator on the session row (hook v17, `-tool` state file with whitelisted summaries), plan-then-execute progress badge driven by `TaskCreated`/`TaskCompleted` (hook v18, `-plan` state file), and "Reset session state" now wipes every hook marker. Detail in `CHANGELOG.md` §0.3.0.

---

## Phase: v0.3.1 — Onboarding + accessibility ✅

Shipped 2026-04-30. First-run coachmark tour, replayable from Settings; VoiceOver and reduce-motion pass across every interactive surface; completed plan badges stop lingering across turns. Detail in `CHANGELOG.md` §0.3.1.

## Phase: v0.4.0 — Parallel subagents ✅

Shipped 2026-05-14. `state/<sid>-agents/<tool_use_id>.json` per in-flight subagent (hook v20/v21), the `N agents · duration` row treatment, real project names via `lsof -d cwd`, and a session-row polish pass. Detail in `CHANGELOG.md` §0.4.0.

## Phase: v0.4.x — UI polish + sandbox awareness ✅

Shipped across v0.5.0 – v0.5.3 (2026-05-20 and 2026-05-21). cleat-sandboxed session tracking (hook v25), the cleat advisory banner and its live FSEvents refresh, and the bypass-permissions attention fix that v0.5.1 got wrong and v0.5.2 corrected. Detail in `CHANGELOG.md` §0.5.0 – §0.5.3.

## Phase: v0.6.0 — Launch at login ✅

Shipped 2026-06-09. `LoginItemService` over `SMAppService.mainApp` behind an injectable backend, plus the Settings → General Startup section with its approval-needed branch. Detail in `CHANGELOG.md` §0.6.0.

---

## Phase: v0.7.0 — Agent teams + faithful subagent lifecycle

Hook coverage stopped growing at v0.4.0 while Claude Code kept shipping events. Clyde subscribes to 20 of the 31 documented events, and the eleven it ignores are not evenly spread — they cluster around everything Claude Code gained as it got more autonomous. This phase is the catch-up, and it opens with a correctness fix rather than a feature.

- **Subagent lifecycle keyed on `agent_id`.** *Done 2026-08-25 (hook v28).* Settled by dumping real payloads from a live session rather than trusting the docs, and the answers shaped the design: `SubagentStart` / `SubagentStop` carry `agent_id` and `agent_type` but **no** `tool_use_id`, so the speculative `extract_field tool_use_id` branch that shipped in v0.4.0 was dead code and has been removed; `SubagentStart` carries **no** description, which only ever arrives in `PreToolUse.tool_input`, so a pure re-key would have cost the panel its second line. Hence the two-phase claim: `PreToolUse(Agent)` writes `pending-<tool_use_id>.json`, `SubagentStart` adopts the oldest pending entry of matching type and re-keys it under `agent_id`, `SubagentStop` deletes it, `PostToolUse` sweeps only what was never claimed. Known degradation: N agents of the *same* type dispatched together keep an accurate row count but can swap summaries between siblings. The same dump measured the original bug — `PostToolUse(Agent)` fired 5s ahead of `SubagentStop`, which is how long the row was missing while the agent worked. Two fields worth remembering for later items: `SubagentStop` also carries `last_assistant_message` and `agent_transcript_path`, and `PostToolUse` carries `duration_ms`. **The lesson that cost a rewrite:** the first implementation claimed in one direction only (PreToolUse writes, SubagentStart adopts) and passed every unit test, because the tests drove hook events sequentially. Production does not: Claude fires each event as its own process with no ordering guarantee, and the `PreToolUse` hook is the slower of the two (~490ms vs ~390ms — it probes cleat and shells out to lsof), so `SubagentStart` usually runs first, found nothing to adopt, and the agent never appeared in the panel at all. The merge is therefore symmetric — whichever event lands second completes the record — and guarded by an mkdir-based lock with a bounded wait, so two truly simultaneous hooks cannot both write. Any future test touching this pipeline must be able to run hooks concurrently, or it cannot see this class of bug. The same round also caught a leak: an interrupted agent never emits `SubagentStop`, so `PostToolUseFailure` with `is_interrupt` now sweeps the whole `-agents/` dir.
- **`TeammateIdle`.** Agent teams are entirely invisible to Clyde right now. "A teammate is about to go idle" is the same class of signal Clyde was built around — someone is waiting on you — so it maps onto the existing attention indicator rather than needing new UI. Decide early whether a teammate is its own panel row or a decoration on the parent session's row; that choice drives everything else.
- **`UserPromptExpansion`.** Gives `command_name` before Claude sees the expanded prompt. During a long `/loop` or `/code-review` run the session row currently says "Working" and nothing else. Cheap to wire — it is one more state field on the same one-way bus.
- **`PostToolBatch`.** The `-tool` marker is a single file, so parallel tool calls overwrite each other and the panel shows whichever `PreToolUse` landed last. `batch_id` plus `tool_calls` makes an honest "3 tools" possible. Open design question to settle before coding: does `-tool` become a directory keyed by `tool_use_id` the way `-agents/` already is, or does the batch event alone carry enough to keep it single-file? The directory shape is more consistent with existing code; the single-file shape is less churn.
- **`Stop.last_assistant_message`.** The field already arrives on every `Stop` and the hook drops it. A one-line preview is the cheapest possible "what did it actually say" affordance. Deliberately *not* `MessageDisplay`: full message text on every displayed message is noise, and writing it to disk raises a privacy question this app has so far been able to answer with "we don't".
- **Worktree badge.** `WorktreeCreate` / `WorktreeRemove` carry `worktree_path` and `worktree_name`. Sessions in a worktree currently render an opaque temp path. Visually this is the cleat capsule again, so it is mostly plumbing.
- **Tool-summary whitelist.** `clyde-hook.sh` summarises Edit/Write/Read/Bash/Glob/Grep/Agent/WebFetch/WebSearch and gives everything else an empty summary. `Skill`, `Workflow` and `Artifact` are common enough now to deserve entries — skill name, workflow name, artifact title respectively.

## Phase: v0.7.x — Stabilization

Split out from v0.7.0 deliberately: none of this needs a Ventura VM or an Intel Mac, so it must never be what a feature release waits on. `Testing backlog` below stays the home for the hardware- and wall-time-gated matrix.

- **Per-event regression coverage.** `HookScriptTests` covers a fraction of the 20 handled events. Every event that writes or clears a state file should have a case that pipes a representative payload through the script with a temp `HOME` and asserts on the resulting files — the same shape the existing tests already use, just applied exhaustively.
- **First `ActivityLog` coverage.** `CLAUDE.md` records that `ActivityLog` has no unit tests and that shipping without them is the established pattern. The v0.7.0 subagent rework touches its inputs, which makes this the right moment to break that pattern. Mirror `ProcessMonitorTests`: real instance, temp `stateDir`, drive it by writing marker files.
- **Zombie / GC audit in `-agents/`.** The defensive 30-minute sweep from v0.4.0 assumes `tool_use_id` keying. Re-derive it once `agent_id` lands rather than porting it blindly.
- **`HookInstaller` error paths.** Healthcheck, repair and version-bump branches are the least-exercised code in the app and the most visible when they misfire — a bad healthcheck shows the user a banner about a problem they do not have.

## Phase: v0.8.0 — Session stats & review

Clyde answers "what is Claude doing right now" well and "what did Claude do today" not at all, despite `ActivityLog` already recording most of the raw material. This is the phase that turns a live monitor into something you open on purpose, and it produces the screenshots the content work below has been missing.

- **Daily / weekly review.** Time Claude spent working, turns taken, most-used tools, and how often a session sat waiting on you. That last number is the interesting one — it is the metric nobody else surfaces and the one that justifies having a monitor at all.
- **Per-project breakdown.** Multi-repo days are common and currently illegible after the fact.
- **Retention window.** Stats need history, and history is the one thing Clyde has so far avoided keeping. Pick a default, make it configurable, and make deleting it a single obvious action.
- **Local by construction.** No telemetry, no accounts, no network. The README promises this and the promise is a genuine differentiator, not a limitation to work around.

## Phase: v0.9.0 — Panel actions (two-way channel)

Approving a permission request or sending a prompt straight from Clyde, without switching to the terminal. The biggest draw for new users on this roadmap and the biggest architectural jump — every design note in `clyde-hook.sh` rests on the bus being one-way and advisory, so reversing it changes the trust model and not just the plumbing.

- **Spec before code.** brainstorming → `docs/superpowers/specs/` → writing-plans. Starting from a transport choice is how this phase goes wrong.
- **Known landmines.** The hook must never block or fail noisily, or Claude raises a hook error in the user's session every turn. `PreToolUse` decisions are bounded by Claude's hook timeout, so anything that waits on a human has to fit inside it or fall back cleanly. And any inbound channel is new local attack surface in an app whose current security story is "it only ever writes files".
- **Mechanism first.** Returning `permissionDecision` from the `PreToolUse` hook and an out-of-band channel are meaningfully different products, not two implementations of one. Settle that before designing any UI.

---

## Phase: v0.3.0+ — UX polish, content & reach

Backlog. Pick when there's time or when community interest bumps priority. UX polish items moved here from v0.2.x once the v0.3.0 telemetry work landed — they're not blocking anything, and rolling them into a content/reach push makes more sense than gating a point release on copy review.

### UX polish

Coachmark first-run tour and "Replay welcome tour" in Settings shipped 2026-04-30 — see `CHANGELOG.md` Unreleased section.

- **Accessibility pass.** VoiceOver labels on every control, not just the menu-bar button. Audit `SessionRow`, `PlanBadge`, the tool-summary line, Settings panes, and the activity timeline. Cross-check Dynamic Type and reduced-motion (the `SessionRow` spring slide should fall back to a fade).
- **Copy proofread by a second pair of eyes.** Tooltips, onboarding, settings descriptions, error banners, Sparkle release-note phrasings. Solo dev → blind spot. Bundle with the demo-video script review.

### Content & reach

- **Short demo video (30-60s)** showing busy / ready / attention flow. Primary distribution: landing page hero, README, launch tweet, GitHub social preview.
- **Press kit folder** — logo variants, screenshots at common dimensions, one-paragraph app description, fact sheet.
- **Launch post on Product Hunt and r/ClaudeAI.** Worth holding until the v0.8.0 review surface exists — a monitor is hard to screenshot compellingly, a weekly review is not. Pair with the demo video so both land at once.
- **Refresh the landing page.** It still sells the v0.2.x feature set. Agent teams and session stats are the two things that will bring people in; neither is mentioned.
- **Opt-in crash reporting** (Sentry / KSCrash / Apple MetricKit). Off by default, clear toggle in Settings, plain-language explanation of what gets sent.
- **Opt-in anonymous usage analytics** with the same defaults. Decide first whether it's worth the privacy-policy surface area before wiring anything.
- **App Store yes/no decision.** Implications: sandboxing rewrite of the hook installer (can't write to `~/.claude/` from a sandboxed app without user-granted scoped access), StoreKit instead of Sponsor links, Apple's cut on any paid tier. Likely answer: **no**, stay DMG+Homebrew.
- **Trademark check** on "Clyde" in US/EU databases. Worth doing before any paid tier or App Store submission, not before.

---

## Phase: Testing backlog

Items that need real hardware or long wall time to verify. Not blocking anything specific — just gaps in our matrix.

- **Minimum supported macOS version (13.0 Ventura per `Info.plist`).** Needs a 13.x VM or older Mac. Likely surface area: SwiftUI APIs we may have started using past 13.0 without noticing.
- **Intel Mac.** Universal binary should work but verify launch + hook install + Sparkle update on x86_64.
- **Multiple Claude sessions across multiple terminals simultaneously** — e.g. 4 × Terminal.app + 2 × Warp + 1 × Ghostty, all running distinct sessions. Stress-test reconcile, focus-session targeting, and `-busy` marker churn.
- **All three terminal adapters end-to-end.** Launch Claude from Terminal.app, Warp, and Ghostty in turn, verify the focus-session click jumps to the right window in each.
- **Fresh user account.** No `~/.claude`, no `~/.clyde`. The 0.1.0 smoke test covered this on a dev machine but not a pristine user profile — covers first-run hook install, permission prompts, Settings defaults.
- **24h memory leak / long-running stress test.** Leave Clyde running overnight with a few Claude sessions and watch Activity Monitor for growth. Pair with `leaks` if anything looks off.

---

## Already done, kept for reference

Items that looked open in the pre-launch checklist but turned out to be shipped in 0.1.0 during the sprint. No action needed.

- Acknowledgements sheet (existed before smoke test, re-verified during the audit).
- Diagnostic export (exists as "Copy diagnostic info" in Settings).
- Log rotation (`clyde-hook.sh` rotates `hook.log` at ~512 KiB).
- Privacy-respecting defaults (no telemetry ships in 0.1.0).
