#!/bin/bash
# clyde-hook-version: 11
# Clyde notification hook — signals Clyde about Claude session state transitions.
# Installed automatically by Clyde. Safe to remove manually.
#
# Files are keyed by Claude's session_id (UUID from the hook payload), so
# PID recycling cannot produce false positives. Each file's content is
# JSON with the live PID + cwd, which Clyde reads to do PID-keyed lookups.
#
# Writes are atomic (mktemp + mv) so concurrent hooks can't corrupt files.
#
# Handled events:
#   SessionStart        → state/<session_id>-info (alive marker)
#   SessionEnd          → removes info + busy + event for that session
#   UserPromptSubmit    → state/<session_id>-busy marker (+ backfill -info)
#   Stop                → removes busy + event marker
#   StopFailure         → removes busy marker (abnormal turn termination)
#   PermissionRequest   → events/<session_id>.json (attention flag)
#   PreToolUse          → clears event file + refreshes busy marker mtime
#   PostToolUseFailure  → removes busy marker IF is_interrupt=true (user Ctrl+C)

set -e
EVENTS_DIR="$HOME/.clyde/events"
STATE_DIR="$HOME/.clyde/state"
mkdir -p "$EVENTS_DIR" "$STATE_DIR"

INPUT=$(cat 2>/dev/null || echo "{}")

# Extract a top-level string field from the Claude hook payload.
# Tries python3 first; falls back to a grep-based parser if python3 is
# missing (Apple keeps threatening to remove the system Python).
extract_field() {
    local key=$1
    local value=""

    if command -v python3 >/dev/null 2>&1; then
        value=$(printf '%s' "$INPUT" | python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    d = {}
print(d.get('$key', ''))
" 2>/dev/null) || value=""
    fi

    if [ -z "$value" ]; then
        # Pure-shell fallback: grep the JSON for "key": "value".
        # Handles the common case of unescaped string values (Claude's
        # hook payloads have well-formed UUIDs and absolute paths).
        value=$(printf '%s' "$INPUT" \
            | tr -d '\n' \
            | grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
            | head -n1 \
            | sed -E 's/.*"([^"]*)"$/\1/')
    fi

    printf '%s' "$value"
}

HOOK_EVENT=$(extract_field hook_event_name)
SESSION_ID=$(extract_field session_id)
CWD=$(extract_field cwd)
[ -z "$HOOK_EVENT" ] && HOOK_EVENT="unknown"

find_claude_pid() {
    local pid=$PPID
    local depth=0
    while [ "$pid" -gt 1 ] && [ "$depth" -lt 10 ]; do
        local name=$(ps -p "$pid" -o comm= 2>/dev/null | tr -d ' ')
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
[ -z "$CLAUDE_PID" ] && exit 0

# Fall back to PID-based key if Claude didn't supply session_id.
KEY="${SESSION_ID:-$CLAUDE_PID}"
TIMESTAMP=$(date +%s)

# JSON-escape cwd for safe embedding (just escape backslashes and quotes).
ESC_CWD=$(printf '%s' "$CWD" | sed 's/\\/\\\\/g; s/"/\\"/g')
ESC_SID=$(printf '%s' "$SESSION_ID" | sed 's/\\/\\\\/g; s/"/\\"/g')

# Atomic write helper: stage to a temp file in the same dir, then mv.
atomic_write() {
    local target=$1
    local body=$2
    local tmp
    tmp=$(mktemp "$(dirname "$target")/.clyde-tmp.XXXXXX") || return 1
    printf '%s\n' "$body" > "$tmp"
    mv -f "$tmp" "$target"
}

case "$HOOK_EVENT" in
    SessionStart)
        atomic_write "$STATE_DIR/$KEY-info" \
            "{\"session_id\": \"$ESC_SID\", \"pid\": $CLAUDE_PID, \"cwd\": \"$ESC_CWD\", \"started_at\": $TIMESTAMP}"
        ;;
    SessionEnd)
        rm -f "$STATE_DIR/$KEY-info" "$STATE_DIR/$KEY-busy" "$EVENTS_DIR/$KEY.json"
        ;;
    PermissionRequest)
        atomic_write "$EVENTS_DIR/$KEY.json" \
            "{\"session_id\": \"$ESC_SID\", \"pid\": $CLAUDE_PID, \"cwd\": \"$ESC_CWD\", \"event\": \"$HOOK_EVENT\", \"timestamp\": $TIMESTAMP}"
        ;;
    UserPromptSubmit)
        atomic_write "$STATE_DIR/$KEY-busy" \
            "{\"session_id\": \"$ESC_SID\", \"pid\": $CLAUDE_PID, \"cwd\": \"$ESC_CWD\", \"timestamp\": $TIMESTAMP}"
        # If this is an existing session that predates Clyde, the
        # SessionStart hook never fired for it. Backfill -info so the
        # session "graduates" to full hook tracking from now on.
        if [ ! -f "$STATE_DIR/$KEY-info" ]; then
            atomic_write "$STATE_DIR/$KEY-info" \
                "{\"session_id\": \"$ESC_SID\", \"pid\": $CLAUDE_PID, \"cwd\": \"$ESC_CWD\", \"started_at\": $TIMESTAMP}"
        fi
        ;;
    Stop)
        # Clear both the busy marker AND any pending attention event for
        # this session. Stop means the turn is over — any permission
        # request inside that turn has been resolved by the user.
        rm -f "$STATE_DIR/$KEY-busy" "$EVENTS_DIR/$KEY.json"
        ;;
    StopFailure)
        # Turn ended abnormally (API error, internal failure, ...). The
        # turn is over even though Stop didn't fire — drop the busy
        # marker so Clyde doesn't show the session stuck in "working".
        rm -f "$STATE_DIR/$KEY-busy"
        ;;
    PostToolUseFailure)
        # A tool execution failed. The most important sub-case is the
        # user pressing Ctrl+C to interrupt — Claude Code reports that
        # via `is_interrupt: true` in the payload. When that flag is
        # set, the turn is effectively done and we drop the busy marker
        # immediately so Clyde reflects reality without waiting for the
        # mtime-staleness fallback (~2 min).
        #
        # For non-interrupt failures (command exited non-zero, etc.)
        # Claude usually keeps working and tries to recover, so we
        # leave the busy marker alone in that case.
        if printf '%s' "$INPUT" | grep -q '"is_interrupt"[[:space:]]*:[[:space:]]*true'; then
            rm -f "$STATE_DIR/$KEY-busy"
        fi
        ;;
    PreToolUse)
        # Tools can only run after permission was granted, so clear any
        # pending attention flag. The session stays busy via its marker.
        rm -f "$EVENTS_DIR/$KEY.json"
        # Refresh the busy marker's mtime so Clyde's staleness check
        # doesn't expire it mid-turn. Without this, long tool-using runs
        # would briefly drop to "ready" until the next user interaction.
        # Combined with Clyde's reduced busyMarkerTimeout, this also
        # ensures interrupted sessions (Ctrl+C) without a tool-failure
        # event still clear within ~2 minutes.
        [ -f "$STATE_DIR/$KEY-busy" ] && touch "$STATE_DIR/$KEY-busy"
        ;;
esac

exit 0
