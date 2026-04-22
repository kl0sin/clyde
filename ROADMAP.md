# Clyde Roadmap

Post-v0.2.0 work for Clyde, the macOS menu bar app that watches every
Claude Code session in real time.

Phases follow Clyde's release rhythm. Detail behind each task lives in
[`docs/roadmap.md`](docs/roadmap.md); the historical record of what
shipped is in [`CHANGELOG.md`](CHANGELOG.md) and
[`docs/pre-launch-checklist.md`](docs/pre-launch-checklist.md).

## Phase: v0.2.1 — Sign and ship properly

First signed + notarized release. Single goal: eliminate the
"unidentified developer" Gatekeeper friction that v0.1.0 / v0.2.0
still ship with. No new product features unless a critical bug
demands one.

- [x] Apple Developer Program membership + Developer ID cert ready !hi
- [x] Wire up GitHub Secrets for the release pipeline (cert, password, Apple ID, Sparkle key) !hi
- [ ] First signed + notarized release cut !hi
- [ ] Gatekeeper verification on a clean Mac !hi
- [ ] Activate Sparkle appcast — verify v0.2.0 sees an update !hi
- [ ] Resolve "Commit appcast back to main" vs branch-protection ruleset !md
- [ ] Publish Homebrew cask to `kl0sin/homebrew-tap` !md
- [ ] Update CHANGELOG with signed-release entry, promote resolved Known Limitations !lo
- [ ] Refresh landing page to drop the "unsigned prerelease" warning !lo

## Phase: v0.2.x — Hook pipeline followups + UX polish

Items surfaced by the 0.1.0 / 0.2.0 smoke tests and deferred to
avoid scope creep.

- [ ] Document the `PermissionRequest → deny` hook trace in `clyde-hook.sh` + smoke-test doc !md #hooks
- [ ] Fix phantom `-info` files from recycled PIDs in `discoverPIDs` !md #hooks
- [ ] Investigate `claude --resume` firing two `SessionStart` events ~1 minute apart !lo #hooks
- [ ] Coachmarks / "how to use" tooltip on first panel expand !md #ux
- [ ] Accessibility pass — VoiceOver labels on all controls !md #ux
- [ ] Document keyboard shortcuts (⌃⌘C and friends) in README + Settings !lo #ux
- [ ] Copy proofread by a second pair of eyes !lo #ux

## Phase: v0.3.0+ — Content & reach

Backlog. Pick when there's time or when community interest bumps
priority.

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
