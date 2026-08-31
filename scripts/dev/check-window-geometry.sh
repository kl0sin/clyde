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

LAUNCHED=0
if [ -n "$APP" ]; then
    open "$APP" || { echo "could not launch $APP" >&2; exit 1; }
    LAUNCHED=1
    sleep 12   # the panel is built during launch, before it is ever shown
fi

GEOMETRY=$($GEOMETRY_CMD 2>/dev/null)

if [ "$LAUNCHED" = "1" ]; then
    killall Clyde 2>/dev/null
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

if [ "$FAILED" = "0" ]; then
    echo "PASS — panel $PANEL, widget $WIDGET"
else
    echo "a panel taller than the screen loses its Activity bar off the bottom edge"
fi
exit $FAILED
