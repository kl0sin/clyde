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

## Phase: v0.3.0+ — UX polish, content & reach

Backlog. Pick when there's time or when community interest bumps priority. UX polish items moved here from v0.2.x once the v0.3.0 telemetry work landed — they're not blocking anything, and rolling them into a content/reach push makes more sense than gating a point release on copy review.

### UX polish

Coachmark first-run tour and "Replay welcome tour" in Settings shipped 2026-04-30 — see `CHANGELOG.md` Unreleased section.

- **Accessibility pass.** VoiceOver labels on every control, not just the menu-bar button. Audit `SessionRow`, `PlanBadge`, the tool-summary line, Settings panes, and the activity timeline. Cross-check Dynamic Type and reduced-motion (the `SessionRow` spring slide should fall back to a fade).
- **Copy proofread by a second pair of eyes.** Tooltips, onboarding, settings descriptions, error banners, Sparkle release-note phrasings. Solo dev → blind spot. Bundle with the demo-video script review.

### Content & reach

- **Short demo video (30-60s)** showing busy / ready / attention flow. Primary distribution: landing page hero, README, launch tweet, GitHub social preview.
- **Press kit folder** — logo variants, screenshots at common dimensions, one-paragraph app description, fact sheet.
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
