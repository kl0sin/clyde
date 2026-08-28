#!/usr/bin/env bash
# Reproducible live scenarios for Clyde.
#
# Clyde's failure modes do not show up in unit tests. Every real bug found
# so far — phantom sessions, a badge that never rendered, numbers frozen in
# an open window, a hook that broke someone else's tool — was found by
# putting the app in a specific state and looking at it. This script is
# those states, so checking them again costs one command instead of an hour
# of remembering how.
#
# Usage:
#   scripts/dev/scenarios.sh <scenario>
#   scripts/dev/scenarios.sh list
#
# Every scenario that touches ~/.clyde or ~/.claude backs up what it
# replaces into a snapshot directory and prints how to restore it. Nothing
# here is destructive on its own; `restore` puts everything back.
set -uo pipefail

CLYDE_DIR="$HOME/.clyde"
HOOK_INSTALLED="$HOME/.claude/hooks/clyde-hook.sh"
SNAPSHOT="${TMPDIR:-/tmp}/clyde-scenarios-snapshot"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$REPO_ROOT/.build/debug/Clyde.app"

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
note() { printf '  %s\n' "$*"; }

snapshot_once() {
    mkdir -p "$SNAPSHOT"
    [ -e "$SNAPSHOT/.clyde" ] || { [ -d "$CLYDE_DIR" ] && cp -R "$CLYDE_DIR" "$SNAPSHOT/.clyde"; }
    [ -e "$SNAPSHOT/clyde-hook.sh" ] || { [ -f "$HOOK_INSTALLED" ] && cp "$HOOK_INSTALLED" "$SNAPSHOT/clyde-hook.sh"; }
    note "snapshot: $SNAPSHOT"
}

# Clyde is a login item, so `killall` alone is not enough — macOS relaunches
# the copy in /Applications and you end up measuring the old binary while
# your probes report from the new one. Ask for a count until it is zero.
kill_all_clyde() {
    for _ in 1 2 3 4 5; do
        killall Clyde 2>/dev/null
        sleep 1
        local n
        n=$(osascript -e 'tell application "System Events" to count (every process whose name is "Clyde")' 2>/dev/null || echo 0)
        [ "${n:-0}" = "0" ] && return 0
    done
    note "warning: a Clyde instance survived — check for a second build"
}

build_and_run() {
    say "Building and launching the local build"
    (cd "$REPO_ROOT" && ./scripts/build-app.sh debug >/dev/null) || { note "build failed"; exit 1; }
    kill_all_clyde
    # Install over /Applications so the login item cannot resurrect an older
    # binary behind your back — that cost an hour of chasing a fixed bug.
    rm -rf /Applications/Clyde.app
    cp -R "$APP" /Applications/Clyde.app
    codesign --force --deep --sign - /Applications/Clyde.app >/dev/null 2>&1
    open /Applications/Clyde.app
    sleep 5
    note "running: $(osascript -e 'tell application "System Events" to count (every process whose name is "Clyde")' 2>/dev/null) instance(s)"
}

install_hook() {
    snapshot_once
    cp "$REPO_ROOT/Clyde/Resources/clyde-hook.sh" "$HOOK_INSTALLED"
    chmod 755 "$HOOK_INSTALLED"
    note "installed hook $(grep -m1 'clyde-hook-version' "$HOOK_INSTALLED")"
}

open_panel() {
    osascript >/dev/null 2>&1 <<'OSA'
tell application "System Events" to tell process "Clyde"
  click menu bar item 1 of menu bar 2
  delay 1
  click menu item "Show Clyde" of menu 1 of menu bar item 1 of menu bar 2
end tell
OSA
    sleep 2
}

shot() {
    local out="${TMPDIR:-/tmp}/clyde-scenario-$1.png"
    screencapture -x "$out"
    note "screenshot: $out"
    osascript -e 'tell application "System Events" to tell process "Clyde" to get {position, size} of every window' 2>/dev/null \
        | sed 's/^/  windows: /'
}

case "${1:-list}" in

list)
    say "Scenarios"
    note "phantom-sessions   running the test suite must not create session rows"
    note "single-agent       one running subagent must be visible in its parent row"
    note "fresh-install      a brand-new ~/.clyde must rebuild and still find sessions"
    note "history-review     seed history and open the review window"
    note "settings-history   history size, and whether the numbers go stale"
    note "accessibility      the banner shown when the global shortcut has no permission"
    note "restore            put ~/.clyde and the installed hook back"
    ;;

# The bug: any process named `claude` used to become a session, and the test
# suite's own fixtures are named exactly that. Watch for rows appearing.
phantom-sessions)
    install_hook
    build_and_run
    open_panel
    say "Running HookScriptTests — its fixtures spawn processes named claude"
    (cd "$REPO_ROOT" && swift test --filter HookScriptTests >/dev/null 2>&1) &
    local_pid=$!
    for _ in $(seq 1 60); do
        n=$(ps -eo comm | sed 's|.*/||' | grep -cx 'claude' 2>/dev/null || echo 0)
        [ "${n:-0}" -gt 1 ] && { note "fixtures live: $n processes named claude"; sleep 3; break; }
        sleep 0.3
    done
    shot phantom
    wait $local_pid 2>/dev/null
    say "PASS if the panel shows only your real sessions"
    note "FAIL looks like: extra rows named after the repo directory, status Ended"
    ;;

# One agent used to render nothing at all: every agent affordance was gated
# on there being two.
single-agent)
    install_hook
    build_and_run
    open_panel
    say "Dispatch ONE subagent from a Claude session now (any task taking ~30s)"
    note "waiting for an agent record to appear in $CLYDE_DIR/state/*-agents/"
    for _ in $(seq 1 60); do
        n=$(ls "$CLYDE_DIR"/state/*-agents/*.json 2>/dev/null | wc -l | tr -d ' ')
        [ "${n:-0}" -gt 0 ] && { note "agent records: $n"; sleep 2; break; }
        sleep 2
    done
    shot single-agent
    say "PASS if the row reads '1 agent · Ns' with a nested agent row under it"
    ;;

fresh-install)
    snapshot_once
    kill_all_clyde
    say "Moving ~/.clyde aside"
    rm -rf "${SNAPSHOT}/live-clyde" && mv "$CLYDE_DIR" "${SNAPSHOT}/live-clyde" 2>/dev/null
    install_hook
    build_and_run
    open_panel
    sleep 6
    note "recreated: $(ls "$CLYDE_DIR" 2>/dev/null | tr '\n' ' ')"
    shot fresh-install
    say "PASS if the app recreated events/ and state/ and your active session appears"
    note "restore your real state with: $0 restore"
    ;;

history-review)
    install_hook
    build_and_run
    say "Seeding history"
    DB="$CLYDE_DIR/history/history.sqlite"
    for _ in $(seq 1 20); do [ -f "$DB" ] && break; sleep 1; done
    NOW=$(date +%s)
    {
        echo "INSERT INTO events (ts,event,session_id,project,tool,summary) VALUES"
        echo "($((NOW-3600)),'UserPromptSubmit','s-a','$REPO_ROOT',NULL,NULL),"
        echo "($((NOW-3300)),'PreToolUse','s-a','$REPO_ROOT','Bash','swift test'),"
        echo "($((NOW-3000)),'Stop','s-a','$REPO_ROOT',NULL,NULL),"
        echo "($((NOW-1800)),'UserPromptSubmit','s-a','$REPO_ROOT',NULL,NULL),"
        echo "($((NOW-1200)),'Stop','s-a','$REPO_ROOT',NULL,NULL);"
    } | sqlite3 "$DB"
    note "events now: $(sqlite3 "$DB" 'SELECT COUNT(*) FROM events;')"
    osascript >/dev/null 2>&1 <<'OSA'
tell application "System Events" to tell process "Clyde"
  click menu bar item 1 of menu bar 2
  delay 1
  click menu item "Session review…" of menu 1 of menu bar item 1 of menu bar 2
end tell
OSA
    sleep 3
    shot history-review
    say "PASS if working time reads 15m, waiting 10m, turns 2, and the project is listed"
    ;;

settings-history)
    build_and_run
    osascript >/dev/null 2>&1 <<'OSA'
tell application "System Events" to tell process "Clyde"
  click menu bar item 1 of menu bar 2
  delay 1
  click menu item "Settings..." of menu 1 of menu bar item 1 of menu bar 2
end tell
OSA
    sleep 3
    shot settings-before
    say "Now: open Advanced, note the count, then run this while the window stays open:"
    note "sqlite3 $CLYDE_DIR/history/history.sqlite 'DELETE FROM events WHERE id % 2 = 0;'"
    note "Switch to General and back to Advanced."
    say "PASS if the number changed. FAIL means the section only loads once per window."
    ;;

accessibility)
    build_and_run
    open_panel
    shot accessibility
    say "PASS if a banner says the global shortcut has no permission"
    note "A locally built app has a different signature than the release, so macOS"
    note "drops the Accessibility grant — that is the state this banner exists for."
    ;;

restore)
    say "Restoring"
    kill_all_clyde
    [ -d "${SNAPSHOT}/live-clyde" ] && { rm -rf "$CLYDE_DIR"; mv "${SNAPSHOT}/live-clyde" "$CLYDE_DIR"; note "~/.clyde restored"; }
    [ -f "$SNAPSHOT/clyde-hook.sh" ] && { cp "$SNAPSHOT/clyde-hook.sh" "$HOOK_INSTALLED"; note "hook restored: $(grep -m1 'clyde-hook-version' "$HOOK_INSTALLED")"; }
    note "the /Applications copy is whatever you last built — reinstall a release if you want one"
    ;;

*)
    echo "unknown scenario: $1"
    "$0" list
    exit 1
    ;;
esac
