# Clyde — Pre-Launch Checklist

Tracking everything that needs to be in place before publishing Clyde
to users. Items checked off below have been verified against the
current codebase; items still open require either implementation or
manual verification.

> See also: [`hook-smoke-test.md`](hook-smoke-test.md) for the manual
> end-to-end checklist of the hook pipeline, and
> [`release-process.md`](release-process.md) for the day-of release
> mechanics.

## Onboarding & First Run

- [x] First-launch onboarding flow (welcome, what Clyde does, what it needs) — `OnboardingView.swift`, presented from `AppDelegate.showOnboardingIfNeeded()`
- [x] Request notification permission with clear explanation of why — `NotificationService.requestPermission()` called from `AppViewModel.start()`
- [x] Prompt to install the Claude Code hook (with opt-out) — `HookInstaller` + `hookOptOutKey` in `AppViewModel`
- [x] Auto-install / auto-repair if hook is missing or corrupted — `ensureHookHealthy()` runs at start, on 60s tick, on FSEvents from `~/.claude/hooks/` and `~/.claude/settings.json`
- [ ] Detect missing/uninstalled Claude Code and show a helpful message
- [ ] Quick "how to use" tooltip or coachmarks on first expand

## Code Signing & Notarization

- [x] Apple Developer ID certificate set up — see `release-process.md` §1
- [x] App signed with Developer ID Application certificate — `scripts/release/sign.sh`
- [x] Hardened Runtime enabled — `scripts/release/sign.sh`
- [x] Entitlements reviewed and minimized — `scripts/release/Clyde.entitlements`
- [x] App notarized via `notarytool` — `scripts/release/notarize.sh`
- [x] Notarization stapled to the `.app` bundle — same script
- [ ] Verify Gatekeeper accepts the signed app on a clean Mac (manual)

## Distribution

- [x] DMG with drag-to-Applications layout — `scripts/release/make-dmg.sh`
- [x] Sparkle auto-updater integrated — `Sparkle` SPM dep + `SUFeedURL` / `SUPublicEDKey` in `Info.plist`
- [x] Appcast feed hosted somewhere stable — `site/appcast.xml` deployed via GitHub Pages
- [x] Homebrew cask drafted — `Casks/clyde.rb` (still needs to be submitted to a tap repo on first release)
- [x] GitHub Releases set up with versioned artifacts — `.github/workflows/release.yml`
- [ ] Decide on App Store distribution (yes/no) — implications for sandboxing

## Reliability & Telemetry

- [ ] Opt-in crash reporting (Sentry / KSCrash / Apple's MetricKit)
- [ ] Opt-in anonymous usage analytics — clear toggle in Settings
- [x] Privacy-respecting defaults (telemetry OFF until explicitly enabled) — there is no telemetry at all today
- [x] Log file rotation — `clyde-hook.sh` rotates `~/.clyde/logs/hook.log` at ~512 KiB; macOS unified logging handles app logs
- [x] Diagnostic export — "Copy diagnostics" in `SettingsView`
- [ ] "Reveal logs in Finder" button in Settings

## Marketing & Web Presence

- [x] README with screenshots, install instructions — `README.md`, screenshots in `site/img/screenshots/`
- [x] Landing page (one-pager) with download button — `site/index.html`
- [x] App icon finalized at all required sizes — `Clyde/Resources/AppIcon.icns`
- [x] Social preview image for the landing page — `site/img/og-preview.png`
- [ ] Short demo video (30-60s) showing the busy/ready/attention flow
- [ ] Press kit folder (logo, screenshots, app description)

## Legal & Policy

- [x] Privacy policy — `site/privacy.html`
- [x] License chosen and added to repo — MIT, `LICENSE` file at root
- [ ] Third-party licenses screen in About / Settings (Sparkle uses MIT, but it should be surfaced to the user)
- [ ] Terms of use / EULA — likely unnecessary given MIT, decide explicitly
- [ ] Trademark check on the name "Clyde"

## QA & Compatibility

- [x] Hook reinstall / repair flow has unit + smoke coverage — `HookInstallerTests`, `docs/hook-smoke-test.md` scenarios 1–3
- [x] Hook pipeline regression tests — `ProcessMonitorTests`, `HookInstallerTests` (matcher, migration, coexistence, identity check)
- [x] Test suite is deterministic and hermetic — 55/55 passing, isolated via `AppPaths.homeOverride`
- [ ] Manual run of `docs/hook-smoke-test.md` scenarios 1–6 against a fresh `claude` install
- [ ] Test on minimum supported macOS version (currently 13.0 per `Info.plist`)
- [ ] Test on Intel + Apple Silicon (universal binary)
- [ ] Test with multiple Claude Code sessions across multiple terminals
- [ ] Test all supported terminal adapters (Terminal.app, Warp, Ghostty — see `TerminalLauncher.allAdapters`)
- [ ] Test with no Claude Code installed
- [ ] Test on a fresh user account (no `~/.claude`, no `~/.clyde`)
- [ ] Memory leak / long-running session test (24h+)

## Polish

- [ ] App icon in Dock and menu bar both look correct
- [ ] All copy proofread (English)
- [ ] Keyboard shortcuts documented (⌃⌘C global hotkey is implemented in `AppDelegate.registerGlobalHotKey()`)
- [ ] Settings reset confirmation flows feel safe
- [ ] Accessibility pass (VoiceOver labels on key controls — menu bar button has `setAccessibilityLabel`, rest unverified)

## Release Mechanics

- [x] Versioning scheme decided — semver, currently `0.1.0` in `Info.plist`
- [x] CHANGELOG.md exists at repo root
- [x] Release script / GitHub Action that builds, signs, notarizes, uploads — `.github/workflows/release.yml` + `scripts/release/*`
- [x] Sparkle EdDSA keypair generated and `SUPublicEDKey` set in `Info.plist`
- [ ] Tag → release flow tested end-to-end on a dry run
- [ ] First release cut (`v0.1.0`) — gated on the manual smoke test pass
