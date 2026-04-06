#!/bin/bash
# Clyde notification hook — signals Clyde that a Claude session needs attention
# Installed automatically by Clyde's Settings → Claude Integration
#
# Reads hook JSON from stdin, finds the claude process PID by walking up
# from this script's parent, and writes an event file Clyde polls.

set -e

EVENTS_DIR="$HOME/.clyde/events"
mkdir -p "$EVENTS_DIR"

# Read the hook payload (may be needed for details later)
INPUT=$(cat 2>/dev/null || echo "{}")
HOOK_EVENT=$(echo "$INPUT" | /usr/bin/python3 -c "import json,sys; d=json.load(sys.stdin) if sys.stdin.read() else {}; print(d.get('hook_event_name', 'unknown'))" 2>/dev/null || echo "unknown")

# Walk up process tree to find the claude process
find_claude_pid() {
    local pid=$PPID
    local depth=0
    while [ "$pid" -gt 1 ] && [ "$depth" -lt 10 ]; do
        local name=$(ps -p "$pid" -o comm= 2>/dev/null | tr -d ' ')
        # comm returns basename, so just "claude" (not a full path)
        if [ "$(basename "$name")" = "claude" ]; then
            echo "$pid"
            return 0
        fi
        pid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ')
        depth=$((depth + 1))
    done
    return 1
}

CLAUDE_PID=$(find_claude_pid || echo "")

if [ -n "$CLAUDE_PID" ]; then
    TIMESTAMP=$(date +%s)
    cat > "$EVENTS_DIR/$CLAUDE_PID.json" <<EOF
{"pid": $CLAUDE_PID, "event": "$HOOK_EVENT", "timestamp": $TIMESTAMP}
EOF
fi

# Always exit 0 — never block Claude
exit 0
