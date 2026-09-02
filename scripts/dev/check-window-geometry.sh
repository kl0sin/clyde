#!/usr/bin/env bash
# Checks that Clyde's windows are the size they declare.
#
# v0.8.0 shipped an expanded panel of 400x1476 instead of 400x420 —
# three times its height, hanging off the bottom of the screen with the
# Activity bar out of reach. It never reproduced on the development
# machine, because the release is compiled against an older macOS SDK
# whose SwiftUI measures the session list differently. The only honest
# check is to measure a bundle built the way the release is built.
#
# The measurement itself needs no permission: the expanded panel exists
# from launch at alpha 0, and CGWindowListCopyWindowInfo reads it there.
# Driving this through System Events, as this check used to, needs
# Automation permission and fails outright when macOS has not granted
# it — which is what made the original regression so expensive to prove.
#
# Usage:
#   check-window-geometry.sh --app <path/to/Clyde.app> [--strict]
#   check-window-geometry.sh --running [--strict]
#
#   --strict  a machine that shows no windows at all is a failure rather
#             than a skip. Releases use this: a runner that quietly
#             stops being able to measure would quietly stop protecting
#             anything.
set -uo pipefail

EXPECTED_PANEL="400x420"
EXPECTED_WIDGET="130x46"

# Compact's height is computed rather than declared, which is a
# different risk from the one above and needs a different assertion.
# There is no single right answer — the window is as tall as what it
# shows — but the set of right answers is small and countable:
#
#   grip 14 + list padding 8 + separator 0.5 + rows*40 + footer 34
#
# so every legitimate height is 56.5 + 40n, rounded. A height outside
# that set means the calculation is wrong, which is exactly the fault
# that shipped twice in one day: an advisory missing from the sum, and
# then an estimate for it eleven points short.
#
# An open permission request or advisory adds to the height and is not
# in the set. Neither exists on a runner, which is where this runs.
COMPACT_ROW=40
COMPACT_CHROME=57          # 56.5, rounded the way the window reports it
COMPACT_MAX_ROWS=10        # the row cap's ceiling
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

APP=""
RUNNING=0
STRICT=0
while [ $# -gt 0 ]; do
    case "$1" in
        --app) APP="$2"; shift 2 ;;
        --running) RUNNING=1; shift ;;
        --strict) STRICT=1; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$APP" ] && [ "$RUNNING" = "0" ]; then
    echo "usage: $0 --app <path> [--strict] | --running [--strict]" >&2
    exit 2
fi

# Overridable so the assertion logic can be tested without launching
# anything. Production callers never set it.
GEOMETRY_CMD="${CLYDE_GEOMETRY_CMD:-swift $REPO_ROOT/scripts/dev/window-geometry.swift Clyde}"

# The mode is a stored preference, so the first measurement cannot
# assume which one the app will open in — on a development machine it
# opens in whatever was last used, and the check then measures compact
# against the full panel's expectation and fails for no reason.
BUNDLE_ID=""
PREVIOUS_MODE=""
restore_mode() {
    [ -n "$BUNDLE_ID" ] || return 0
    if [ -n "$PREVIOUS_MODE" ]; then
        defaults write "$BUNDLE_ID" panelMode "$PREVIOUS_MODE"
    else
        defaults delete "$BUNDLE_ID" panelMode 2>/dev/null
    fi
}

# `open` on a running app only brings it forward, so a mode written to
# the preference would never be read. Every launch here starts from no
# running copy.
launch_and_measure() {
    local mode="$1"
    # Kill before writing: a terminating copy flushes its own defaults
    # and would overwrite the mode we are about to ask for.
    killall Clyde 2>/dev/null
    while pgrep -f "Clyde.app/Contents/MacOS" >/dev/null; do sleep 0.2; done
    [ -z "$BUNDLE_ID" ] || defaults write "$BUNDLE_ID" panelMode "$mode"
    open "$APP" || { echo "could not launch $APP" >&2; exit 1; }
    sleep 12   # the panel is built during launch, before it is ever shown
    $GEOMETRY_CMD 2>/dev/null
    killall Clyde 2>/dev/null
}

if [ -n "$APP" ]; then
    # PlistBuddy rather than `defaults read`, which silently returns
    # nothing for a relative bundle path — and an empty bundle id here
    # means the mode is never set and both measurements are whatever the
    # machine happened to be left in.
    BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist" 2>/dev/null)
    if [ -z "$BUNDLE_ID" ]; then
        echo "::error::could not read CFBundleIdentifier from $APP — cannot choose the panel mode"
        exit 1
    fi
    PREVIOUS_MODE=$(defaults read "$BUNDLE_ID" panelMode 2>/dev/null || echo "")
    trap restore_mode EXIT
    GEOMETRY=$(launch_and_measure full)
else
    GEOMETRY=$($GEOMETRY_CMD 2>/dev/null)
fi

if [ -z "$GEOMETRY" ]; then
    if [ "$STRICT" = "1" ]; then
        echo "::error::no Clyde windows found — this check measured nothing"
        exit 1
    fi
    echo "SKIPPED: no Clyde windows visible here (no window server)"
    exit 0
fi

echo "$GEOMETRY"
PANEL=$(printf '%s\n' "$GEOMETRY" | awk '{print $1}' | grep '^400x' | head -1)
WIDGET=$(printf '%s\n' "$GEOMETRY" | awk '{print $1}' | grep '^130x' | head -1)

FAILED=0
if [ "$PANEL" != "$EXPECTED_PANEL" ]; then
    echo "::error::expanded panel is ${PANEL:-missing}, expected $EXPECTED_PANEL"
    FAILED=1
fi
if [ "$WIDGET" != "$EXPECTED_WIDGET" ]; then
    echo "::error::widget is ${WIDGET:-missing}, expected $EXPECTED_WIDGET"
    FAILED=1
fi

# --- compact, if we launched the app ourselves -----------------------
# Only meaningful when this script controls the launch: it switches the
# mode through the same default the scenario scripts use, which needs a
# relaunch to take effect.
if [ -n "$APP" ] && [ "$FAILED" = "0" ]; then
        COMPACT_GEOMETRY=$(launch_and_measure compact)

        COMPACT=$(printf '%s\n' "$COMPACT_GEOMETRY" | awk '{print $1}' | grep '^400x' | head -1)
        COMPACT_H=${COMPACT#400x}
        if [ -z "$COMPACT_H" ]; then
            echo "::error::compact panel missing — measured nothing"
            FAILED=1
        else
            MATCHED=0
            for n in $(seq 1 $COMPACT_MAX_ROWS); do
                [ "$COMPACT_H" = "$((COMPACT_CHROME + COMPACT_ROW * n))" ] && MATCHED=1 && break
            done
            if [ "$MATCHED" = "0" ]; then
                echo "::error::compact panel is ${COMPACT_H}pt tall, which is not $COMPACT_CHROME + ${COMPACT_ROW}n for any row count"
                echo "a height outside that set means something is drawn that the height calculation does not know about"
                FAILED=1
            else
                echo "compact $COMPACT — a valid height for its rows"
            fi
        fi
fi

if [ "$FAILED" = "0" ]; then
    echo "PASS — panel $PANEL, widget $WIDGET, compact ${COMPACT:-not measured}"
else
    echo "a window that is not the size it declares is one the user cannot fully see"
fi
exit $FAILED
