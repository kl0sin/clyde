# Clyde — Pre-Launch Checklist

Tracking everything that needs to be in place before publishing Clyde to users.

## Onboarding & First Run

- [ ] First-launch onboarding flow (welcome, what Clyde does, what it needs)
- [ ] Request notification permission with clear explanation of why
- [ ] Prompt to install the Claude Code hook (with opt-out)
- [ ] Detect missing/uninstalled Claude Code and show a helpful message
- [ ] Quick "how to use" tooltip or coachmarks on first expand

## Code Signing & Notarization

- [ ] Apple Developer ID certificate set up
- [ ] App signed with Developer ID Application certificate
- [ ] Hardened Runtime enabled
- [ ] Entitlements reviewed and minimized
- [ ] App notarized via `notarytool`
- [ ] Notarization stapled to the `.app` bundle
- [ ] Verify Gatekeeper accepts the signed app on a clean Mac

## Distribution

- [ ] DMG with background image and drag-to-Applications layout
- [ ] Sparkle (or equivalent) auto-updater integrated
- [ ] Appcast feed hosted somewhere stable
- [ ] Homebrew cask submitted
- [ ] GitHub Releases set up with versioned artifacts
- [ ] Decide on App Store distribution (yes/no) — implications for sandboxing

## Reliability & Telemetry

- [ ] Opt-in crash reporting (Sentry / KSCrash / Apple's MetricKit)
- [ ] Opt-in anonymous usage analytics — clear toggle in Settings
- [ ] Privacy-respecting defaults (telemetry OFF until explicitly enabled)
- [ ] Log file rotation and a "Reveal logs in Finder" button
- [ ] Diagnostic export already exists — verify it captures enough

## Marketing & Web Presence

- [ ] README with screenshots, GIF demo, install instructions
- [ ] Landing page (one-pager) with download button
- [ ] App icon finalized at all required sizes
- [ ] Social preview image for the landing page
- [ ] Short demo video (30-60s) showing the busy/ready/attention flow
- [ ] Press kit folder (logo, screenshots, app description)

## Legal & Policy

- [ ] Privacy policy (even if Clyde sends nothing — state that explicitly)
- [ ] Terms of use / EULA
- [ ] License chosen and added to repo (MIT? Apache? proprietary?)
- [ ] Third-party licenses screen in About / Settings
- [ ] Trademark check on the name "Clyde"

## QA & Compatibility

- [ ] Test on minimum supported macOS version
- [ ] Test on Intel + Apple Silicon (universal binary)
- [ ] Test with multiple Claude Code sessions across multiple terminals
- [ ] Test all supported terminal adapters (Terminal, iTerm, Ghostty, Warp)
- [ ] Test with no Claude Code installed
- [ ] Test hook reinstall / repair flow
- [ ] Test full reset flow
- [ ] Test on a fresh user account (no `~/.claude`, no `~/.clyde`)
- [ ] Memory leak / long-running session test (24h+)

## Polish

- [ ] App icon in Dock and menu bar both look correct
- [ ] All copy proofread (English)
- [ ] Keyboard shortcuts documented
- [ ] Settings reset confirmation flows feel safe
- [ ] Accessibility pass (VoiceOver labels on key controls)

## Release Mechanics

- [ ] Versioning scheme decided (semver?)
- [ ] CHANGELOG.md started
- [ ] Release script / GitHub Action that builds, signs, notarizes, uploads
- [ ] Tag → release flow tested end-to-end on a dry run
