#!/bin/bash
# clyde-statusline-version: 1
# Clyde status-line wrapper — copies what Claude Code tells the status
# line into ~/.clyde/usage/ so Clyde can show the subscription limits.
# Installed by Clyde. Safe to remove; Clyde's Settings restores your own
# status line command when the feature is turned off.
#
# Advisory, like the hook: never `set -e`, always exit 0. A status line
# that exits non-zero or prints nothing goes blank in the terminal.

USAGE_DIR="$HOME/.clyde/usage"
LOG_DIR="$HOME/.clyde/logs"
LOG="$LOG_DIR/statusline.log"
mkdir -p "$USAGE_DIR" "$LOG_DIR" 2>/dev/null || true

trap 'rc=$?; printf "[%s] clyde-statusline line %s exited %s\n" "$(date "+%Y-%m-%d %H:%M:%S")" "$LINENO" "$rc" >>"$LOG" 2>/dev/null; exit 0' ERR

INPUT=$(cat 2>/dev/null || echo "{}")

# The whole payload, atomically. Parsing is Clyde's job: this runs
# after every API response and cannot depend on jq being installed.
tmp=$(mktemp "$USAGE_DIR/.snapshot.XXXXXX" 2>/dev/null) || tmp=""
if [ -n "$tmp" ]; then
    if printf '%s\n' "$INPUT" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$USAGE_DIR/statusline.json" 2>/dev/null || rm -f "$tmp"
    else
        rm -f "$tmp"
    fi
fi

# The user's own status line, if they had one before Clyde. Same stdin,
# their output. Its failures are its own; ours is still exit 0.
if [ -s "$USAGE_DIR/passthrough" ]; then
    THEIRS=$(cat "$USAGE_DIR/passthrough" 2>/dev/null)
    printf '%s' "$INPUT" | /bin/bash -c "$THEIRS" 2>/dev/null || true
    exit 0
fi

# No status line before Clyde: one line, the model and the two windows.
LINE=""
if command -v python3 >/dev/null 2>&1; then
    LINE=$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
parts = []
model = (d.get("model") or {}).get("display_name")
if model:
    parts.append(str(model))
rl = d.get("rate_limits") or {}
for key, label in (("five_hour", "5h"), ("seven_day", "7d")):
    w = rl.get(key) or {}
    p = w.get("used_percentage")
    if isinstance(p, (int, float)):
        parts.append("%s %d%%" % (label, int(round(p))))
print(" · ".join(parts))
' 2>/dev/null) || LINE=""
fi
if [ -z "$LINE" ]; then
    # No python3: the model name is enough to keep the line from going blank.
    LINE=$(printf '%s' "$INPUT" | tr -d '\n' \
        | grep -o '"display_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 \
        | sed -E 's/.*"([^"]*)"$/\1/')
fi
printf '%s\n' "$LINE"
exit 0
