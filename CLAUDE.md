# Clyde — repo conventions for Claude Code

Clyde is a SwiftUI menu-bar utility (LSUIElement, macOS 13+) that watches Claude Code sessions in real time. Most architecture is discoverable from the source — this file captures conventions and process gotchas that *aren't* visible from grep.

## Commits & attribution

- **Never** add `🤖 Generated with Claude Code`, `Generated with Claude`, or any equivalent footer to commit messages.
- **Never** add `Co-Authored-By: Claude …` (or any Claude/Anthropic identity) to commits.
- **Never** insert generated-by markers into source files, docs, comments, README, CHANGELOG, or any other artifact.

Commits should look exactly as if a human wrote them. Author and co-author fields stay clean.

## Commit style

- Conventional commits: `fix(scope): …`, `feat(scope): …`, `docs(scope): …`, `ci(scope): …`, `chore(scope): …`. Release commits are exactly `release: vX.Y.Z`. Workflow-emitted commits use `chore(release): …` (e.g. `chore(release): appcast for v0.2.3`).
- Stage specific paths. **Never** `git add -A` / `git add .` — it drags in `package-lock.json` and other unintended files. Use `git add <path>` per file.
- Body explains *why*, not what. Avoid line-number references; they rot.
- Direct push to `main` is allowed (the user is on the branch-protection bypass list, and the release workflow pushes back to main as `github-actions[bot]`). **Always confirm with the user before `git push`** — a push is visible / shared state. Tag push to `vX.Y.Z` is *especially* high-impact: it triggers a public, signed, notarized release.

## Tests

- `swift test` from the repo root runs the full Swift suite (~62 tests at present). Run it before every commit that touches Swift.
- Hook script changes need a manual smoke-test: pipe a fake hook payload to `Clyde/Resources/clyde-hook.sh` with `HOME=/tmp/...` and inspect `~/.clyde/logs/hook.log`.
- `ActivityLog` has no unit tests. Existing changes have shipped without tests and that's the established pattern. If you add coverage, mirror the integration style in `ProcessMonitorTests` (real `ProcessMonitor` + temp `stateDir`, drive via writing `-info` files).

## Hook script

- `Clyde/Resources/clyde-hook.sh` carries a `# clyde-hook-version: N` line. **Bump it on every change** *and* update `HookInstaller.currentScriptVersion` in `Clyde/Services/HookInstaller.swift` to the same number — Clyde reinstalls the bundled hook when the installed copy is older.
- The hook is purely advisory: never `set -e`, always `exit 0`. A non-zero exit raises a "Stop hook error" in the user's Claude session every turn.
- Always-on log format is `[YYYY-MM-DD HH:MM:SS] event=NAME sid=… ppid=… pid=… cwd=…` plus optional `source=…` (only on `SessionStart`). Adding fields is fine — append at the end so existing log greps don't break.

## Release process

1. Edit `CHANGELOG.md`: leave `## [Unreleased]` empty, add `## [X.Y.Z] — YYYY-MM-DD` underneath with a one-paragraph intro plus user-facing bullets. Sparkle's update dialog and the GitHub Release body both render this section, so write for end users.
2. `git commit -m "release: vX.Y.Z"` — that commit is just the CHANGELOG bump.
3. `git push origin main`, then `git tag vX.Y.Z <release-commit>`, then `git push origin vX.Y.Z`. The tag push is the trigger.
4. `.github/workflows/release.yml` then builds, signs, notarizes the DMG, and:
   - extracts the `## [X.Y.Z]` CHANGELOG section via `scripts/release/extract-release-notes.sh` and feeds it as the GitHub Release `body_path` (no manual paste needed);
   - pushes a Sparkle appcast entry to `site/appcast.xml` (markdown converted to HTML via `scripts/release/md_to_html.py`);
   - bumps `Casks/clyde.rb` and pushes it to `kl0sin/homebrew-tap`;
   - publishes the GitHub Release with the DMG attached.
5. The workflow auto-commits `chore(release): appcast for vX.Y.Z` and `chore(release): cask bump for vX.Y.Z` back to `main`. `git pull --rebase` before the next local commit — those land between yours.

**Don't bump `Clyde/Info.plist` versions locally.** The workflow stamps `CFBundleShortVersionString` and `CFBundleVersion` via PlistBuddy at build time. The committed Info.plist stays at the dev placeholder (`0.1.0` / `1`).

`scripts/release/update-appcast.sh` and `update-cask.sh` both read `RELEASE_VERSION` from the environment (the workflow passes it explicitly). Don't remove that plumbing — v0.2.2 shipped a cask pointing at a nonexistent DMG because the env var wasn't being threaded through.

## ROADMAP conventions

- `ROADMAP.md` uses `[ ]` / `[x]` with inline priority `!hi` / `!md` / `!lo` and topic tags `#hooks` / `#ux` / `#release` / `#qa`.
- When ticking off an item, replace its description with a one-line summary of what was actually done. The original spec belongs in git history.
- Investigative items often surface follow-up bugs. Add those as fresh `[ ] …` lines in the same phase rather than burying them in the just-completed item's prose.
- Phases follow the release rhythm: `v0.2.x` (current polish), `v0.3.0` (next feature wave), `v0.3.0+` (backlog), `Testing backlog` (needs hardware / wall time).

## Markdown style

Prose markdown files (CHANGELOG, ROADMAP, README, CLAUDE, `docs/*.md`) are **not hard-wrapped** — each paragraph and each list item is one long line. Modern renderers re-flow, and a single-sentence edit shows as a single-line diff. Code fences, headings, tables, blockquotes, and embedded HTML stay verbatim. Don't reintroduce hard-wraps when editing.

`docs/superpowers/{plans,specs}/*.md` are frozen historical artefacts — leave their original wrapping untouched.

## Dates

The user is in Europe (Polish); commit dates and CHANGELOG headings use ISO 8601 (`YYYY-MM-DD`). When the user mentions relative dates ("Thursday", "next week"), resolve them to absolute dates before committing — relative phrasing decays in artefacts.
