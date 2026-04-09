# Roadmap

Post-v0.1.0 work, sorted by priority and version target. Items here
come from the pre-launch checklist leftovers, the hook pipeline
followups captured during the 0.1.0 smoke test, and product ideas we
deferred to ship v0.1.0 faster.

> See also: [`pre-launch-checklist.md`](pre-launch-checklist.md) for
> the historical record of what we shipped in 0.1.0 and
> [`hook-smoke-test.md`](hook-smoke-test.md) for the manual smoke
> test scenarios.

---

## v0.1.1 — "Sign and ship properly"

First point release. Main goal: fix the Gatekeeper-unsigned-warning
friction that v0.1.0 ships with. Zero new product features unless a
critical bug demands one.

### Blockers

- [ ] **Apple Developer Program membership active** — confirm
  membership, team ID, Developer ID Application cert.
- [ ] **Wire up GitHub Secrets** for the release pipeline:
  - `DEVELOPER_ID_CERT_P12_BASE64` (base64 of exported `.p12`)
  - `DEVELOPER_ID_CERT_PASSWORD`
  - `DEVELOPER_ID_APPLICATION` (full identity name)
  - `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`
  - `SPARKLE_PRIVATE_KEY` (from Sparkle's `generate_keys`)
  - See `docs/release-process.md` §1–6 for detailed setup.
- [ ] **First signed + notarized cut.** Tag `v0.1.1`, push, watch the
  workflow run. Unlike v0.1.0, the signing / notarize / appcast
  steps should fire this time. Confirm the release body is the
  "signed" variant, not the unsigned prerelease one.
- [ ] **Gatekeeper verification** on a clean Mac. Download the DMG
  from the release, open it on a machine that has never run Clyde,
  confirm it launches without the "unidentified developer" warning
  and stays quarantine-clean.
- [ ] **Activate Sparkle appcast.** Workflow should auto-publish
  `site/appcast.xml` on release. Verify by running Clyde v0.1.0 and
  checking if "Update available" appears pointing at v0.1.1.
- [ ] **Resolve the "Commit appcast back to main" step vs branch
  protection ruleset.** The release workflow pushes `site/appcast.xml`
  directly to main after a signed cut. Tier-1 branch protection on
  main (enabled after v0.1.0 shipped) blocks direct pushes unless
  the actor is in the ruleset bypass list, and the built-in
  `github-actions[bot]` identity is **not** listable in the bypass
  UI. Pick one of: (a) generate a PAT with `contents: write` +
  `bypass rulesets`, store as `RELEASE_PUSH_TOKEN`, use it in that
  step instead of `GITHUB_TOKEN`; (b) rewrite the step to open a
  PR with the appcast update and merge it manually — extra gate
  per release, ~15 lines of yaml; (c) deploy key + "Deploy keys"
  bypass — heavyweight. Recommendation: **(b)**, because for solo
  dev it doubles as a release review checkpoint.
- [ ] **Publish Homebrew cask** to a dedicated tap repo
  (`kl0sin/homebrew-tap`). README's Homebrew section was removed for
  0.1.0 — add it back once `brew tap kl0sin/tap && brew install
  --cask clyde` actually works.

### Nice-to-have in 0.1.1

- [ ] Update `CHANGELOG.md` 0.1.1 entry with the signed-release bits
  and promote the Known Limitations notes (unsigned, Sparkle dormant,
  Homebrew deferred) into the resolved column.
- [ ] Refresh the landing page to drop the "unsigned prerelease"
  warning once 0.1.1 is out.

---

## v0.2.0 — Hook pipeline followups + UX polish

Surfaced by the 0.1.0 smoke test and deferred to avoid scope creep.

### Hook pipeline

- [ ] **Document the `PermissionRequest → deny` path.** Smoke test
  scenario #4 produced this trace:
  ```
  UserPromptSubmit → PreToolUse → PermissionRequest → Stop
  ```
  No second `PreToolUse` after the user's decision. Confirm whether
  Claude emits a second `PreToolUse` on approval (and only skips it
  on deny), and document the contract in `clyde-hook.sh` +
  `hook-smoke-test.md`. Low risk but worth understanding before we
  build new features on top of the hook stream.
- [ ] **Phantom `-info` files from recycled PIDs.** `discoverPIDs`
  only uses `kill(pid, 0)` for liveness, not the same
  `isLiveClaudeProcess` identity check `refreshHookBusyPIDs` uses,
  so a Claude PID that dies and gets recycled to a non-Claude
  binary leaves a phantom `-info` file behind and Clyde shows a
  phantom "idle" row for that recycled process. Cheap to fix by
  routing `discoverPIDs` through the same check. Risk: could drop
  legitimate sessions during the startup window when `ps -o comm=`
  hasn't yet reported "claude". Needs verification.
- [ ] **Investigate `claude --resume` firing two `SessionStart`
  events ~1 minute apart** for the same `session_id` and same PID.
  Observed during smoke test scenario #5. Doesn't break Clyde — the
  revival path is idempotent — but the cause is worth
  understanding. May be a Claude Code reactivation signal we could
  surface in the UI ("session resumed after break"), or a hook
  double-fire bug on their side.

### UX polish

- [ ] **Coachmarks / "how to use" tooltip** on the first panel
  expand. Users who install via DMG and skip reading the README
  currently get no guidance once the app is running.
- [ ] **Accessibility pass** — VoiceOver labels on all controls
  beyond the menu bar button. Currently only the menu bar icon has
  `setAccessibilityLabel`.
- [ ] **Keyboard shortcuts documented** in README + Settings.
  ⌃⌘C is implemented but not discoverable.
- [ ] **All copy proofread** by a second pair of eyes. Tooltips,
  onboarding, settings descriptions, error banners.

---

## v0.3.0+ — Content & reach

Backlog-style. Pick when there's time or when community interest
bumps priority.

- [ ] **Short demo video** (30-60s) showing
  busy / ready / attention flow. Primary distribution: landing
  page hero, README, tweet announcement, GitHub social preview.
- [ ] **Press kit folder** — logo variants, screenshots at common
  dimensions, one-paragraph app description, fact sheet.
- [ ] **Opt-in crash reporting** (Sentry / KSCrash / Apple
  MetricKit). Off by default. Clear toggle in Settings.
- [ ] **Opt-in anonymous usage analytics** with the same defaults.
- [ ] **App Store yes/no** decision. Implications: sandboxing
  rewrite of the hook installer (can't write to `~/.claude/` from
  a sandboxed app without user-granted scoped access), StoreKit
  instead of Sponsor links, Apple's cut on any paid tier. Likely
  answer: **no**, stay DMG+Homebrew to keep the installer simple.
- [ ] **Trademark check** on the name "Clyde" in US/EU databases.
- [ ] **Coachmark re-trigger** from Settings ("Replay welcome
  tour") for users who dismissed it on first run.

---

## Testing backlog

Items that need real hardware or long wall time to verify.

- [ ] Test on minimum supported macOS version (13.0 Ventura per
  `Info.plist`). Needs a 13.x VM or older Mac.
- [ ] Test on Intel Mac. Universal binary should work but verify.
- [ ] Test with multiple Claude Code sessions across multiple
  terminals simultaneously (e.g. 4 × Terminal.app + 2 × Warp +
  1 × Ghostty, all running distinct Claude sessions).
- [ ] Test with all three supported terminal adapters by launching
  Claude from each and verifying the focus-session click works.
- [ ] Test on a fresh user account (no `~/.claude`, no `~/.clyde`).
  0.1.0 smoke test scenario #1 covers this for a dev machine but
  not for a pristine user profile.
- [ ] 24h memory leak / long-running stress test. Leave Clyde
  running overnight with a few Claude sessions and check
  `Activity Monitor` for growth.

---

## Already done, kept for reference

Items that looked open in the pre-launch checklist but turned out
to be shipped in 0.1.0 during our sprint. No action needed.

- Acknowledgements sheet (existed before smoke test, re-verified
  during the audit).
- Diagnostic export (exists as "Copy diagnostic info" in Settings).
- Log rotation (`clyde-hook.sh` rotates `hook.log` at ~512 KiB).
- Privacy-respecting defaults (no telemetry ships in 0.1.0).
