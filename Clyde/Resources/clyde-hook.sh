#!/bin/bash
# clyde-hook-version: 13
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
#   StopFailure         → no-op (Claude Code retries internally; the
#                         turn is NOT actually over, so removing the
#                         busy marker here causes mid-turn flips to
#                         "ready" while Claude is still working)
#   PermissionRequest   → events/<session_id>.json (attention flag)
#   PreToolUse          → clears event file + refreshes busy marker mtime
#   PostToolUseFailure  → removes busy marker IF is_interrupt=true (user Ctrl+C)
#
# This script is purely advisory — Clyde uses it as a one-way signal
# bus. It must NEVER block or fail noisily, otherwise Claude Code
# raises "Stop hook error: Failed with non-blocking status code" in
# the user's session every turn. We deliberately do NOT use `set -e`;
# instead any unexpected failure is logged and the script always
# exits 0.

EVENTS_DIR="$HOME/.clyde/events"
STATE_DIR="$HOME/.clyde/state"
LOG_DIR="$HOME/.clyde/logs"
HOOK_LOG="$LOG_DIR/hook.log"
mkdir -p "$EVENTS_DIR" "$STATE_DIR" "$LOG_DIR" 2>/dev/null || true

# Catch any unexpected error so it lands in the log instead of
# bubbling out as a non-zero exit. Claude treats non-zero exits as
# hook errors and surfaces them to the user every turn.
trap 'rc=$?; printf "[%s] clyde-hook line %s exited %s (event=%s)\n" "$(date "+%Y-%m-%d %H:%M:%S")" "$LINENO" "$rc" "${HOOK_EVENT:-?}" >>"$HOOK_LOG" 2>/dev/null; exit 0' ERR

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

# Always-on event log. One line per invocation. Used to confirm that
# Claude is actually calling us for the events we care about — without
# this, "no -busy markers" is indistinguishable from "hook never ran".
# Cheap (single append, no fsync) and self-rotating below.
log_event() {
    printf "[%s] event=%-22s sid=%s ppid=%s pid=%s cwd=%s\n" \
        "$(date "+%Y-%m-%d %H:%M:%S")" \
        "$HOOK_EVENT" \
        "${SESSION_ID:--}" \
        "$PPID" \
        "${CLAUDE_PID:--}" \
        "${CWD:--}" >>"$HOOK_LOG" 2>/dev/null || true
}
# Rotate the log if it's grown beyond ~512 KiB. Keeps the file small
# enough to tail comfortably while preserving recent history.
if [ -f "$HOOK_LOG" ]; then
    log_size=$(wc -c <"$HOOK_LOG" 2>/dev/null | tr -d ' ')
    if [ -n "$log_size" ] && [ "$log_size" -gt 524288 ] 2>/dev/null; then
        mv -f "$HOOK_LOG" "$HOOK_LOG.1" 2>/dev/null || true
    fi
fi

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
log_event
if [ -z "$CLAUDE_PID" ]; then
    printf "[%s] WARN no claude ancestor for event=%s ppid=%s\n" \
        "$(date "+%Y-%m-%d %H:%M:%S")" "$HOOK_EVENT" "$PPID" \
        >>"$HOOK_LOG" 2>/dev/null || true
    exit 0
fi

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
        # No-op. StopFailure fires on transient Stop-hook failures and
        # API hiccups; Claude Code retries internally and the turn is
        # NOT actually over. Removing the busy marker here caused
        # mid-turn flips to "ready" while Claude was still mid-tool —
        # the very bug we got reports about. Trust Stop / SessionEnd /
        # process death to clean up instead.
        :
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
        # Touch the busy marker so its mtime tracks tool activity (used
        # for diagnostics / activity timeline). Clyde itself no longer
        # expires markers on staleness — they're sticky for as long as
        # the Claude process is alive — but keeping mtime current is
        # cheap and useful.
        [ -f "$STATE_DIR/$KEY-busy" ] && touch "$STATE_DIR/$KEY-busy"
        ;;
esac

exit 0
