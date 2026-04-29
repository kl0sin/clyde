#!/bin/bash
# clyde-hook-version: 17
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
#   SessionStart        → state/<session_id>-info (alive marker, includes source)
#   SessionEnd          → removes info + busy + error + subagent + tool + event
#   UserPromptSubmit    → state/<session_id>-busy marker (+ backfill -info)
#   Stop                → removes busy + error + subagent + tool + event marker
#   StopFailure         → writes state/<session_id>-error with stop_reason
#   PermissionRequest   → events/<session_id>.json (attention flag)
#   PermissionDenied    → clears event file (user denied permission)
#   PreToolUse          → clears event file + refreshes busy mtime + writes -tool
#   PostToolUse         → removes -tool marker
#   PostToolUseFailure  → removes -tool marker; removes busy IF is_interrupt=true
#   CwdChanged          → rewrites state/<session_id>-info with new cwd
#   Elicitation         → events/<session_id>.json (MCP tool input request)
#   ElicitationResult   → clears event file (MCP input answered)
#   SubagentStart       → state/<session_id>-subagent (agent type)
#   SubagentStop        → removes subagent marker
#   Notification        → log only (no state files)
#   PreCompact          → log only (no state files)
#   PostCompact         → log only (no state files)
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

# Extract a string from `tool_input.<key>` in the Claude hook payload.
# Mirrors extract_field's python3 + grep fallback strategy. Returns
# empty string when the key is missing, when tool_input isn't an
# object, or when the value isn't a string.
extract_tool_input_field() {
    local key=$1
    local value=""

    if command -v python3 >/dev/null 2>&1; then
        value=$(printf '%s' "$INPUT" | python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    ti = d.get('tool_input') or {}
    v = ti.get('$key', '')
    print(v if isinstance(v, str) else '')
except Exception:
    print('')
" 2>/dev/null) || value=""
    fi

    if [ -z "$value" ]; then
        # Pure-shell fallback. We can't reliably parse nested JSON
        # without a real parser, so we just look for the first
        # "key": "value" occurrence anywhere in the payload. Acceptable
        # because Claude's tool_input fields use distinct names
        # (file_path, command, pattern, url, query, subagent_type) that
        # don't collide with top-level payload keys.
        value=$(printf '%s' "$INPUT" \
            | tr -d '\n' \
            | grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
            | head -n1 \
            | sed -E 's/.*"([^"]*)"$/\1/')
    fi

    printf '%s' "$value"
}

# Truncate $1 to at most $2 characters, appending an ellipsis if
# truncated. Pure shell, byte-counted (fine for ASCII summaries; the
# whitelisted fields below are all ASCII paths/commands/patterns).
truncate_summary() {
    local s=$1
    local max=$2
    if [ ${#s} -le "$max" ]; then
        printf '%s' "$s"
    else
        printf '%s…' "${s:0:$max}"
    fi
}

# Compute a short summary string for the active tool, based on
# tool_name. Empty for unknown / MCP / TodoWrite tools — Swift will
# render just the tool name in that case.
compute_tool_summary() {
    local tool=$1
    local raw=""
    case "$tool" in
        Edit|Write|Read|MultiEdit|NotebookEdit)
            raw=$(extract_tool_input_field file_path)
            # basename without forking
            printf '%s' "${raw##*/}"
            ;;
        Bash)
            raw=$(extract_tool_input_field command)
            # First line only — collapse any embedded newlines just in
            # case the grep fallback grabbed a multi-line value.
            raw=$(printf '%s' "$raw" | tr '\n' ' ' | head -c 200)
            truncate_summary "$raw" 40
            ;;
        Glob|Grep)
            raw=$(extract_tool_input_field pattern)
            truncate_summary "$raw" 40
            ;;
        Task)
            extract_tool_input_field subagent_type
            ;;
        WebFetch)
            raw=$(extract_tool_input_field url)
            # Extract host: drop scheme, then keep up to next slash.
            raw=${raw#*://}
            printf '%s' "${raw%%/*}"
            ;;
        WebSearch)
            raw=$(extract_tool_input_field query)
            truncate_summary "$raw" 40
            ;;
        *)
            # TodoWrite, MCP tools, and any future built-in fall through
            # to the empty-summary path. Swift renders just tool_name.
            printf ''
            ;;
    esac
}

HOOK_EVENT=$(extract_field hook_event_name)
SESSION_ID=$(extract_field session_id)
CWD=$(extract_field cwd)
[ -z "$HOOK_EVENT" ] && HOOK_EVENT="unknown"

# `source` only ships on SessionStart payloads ("startup", "resume",
# "clear", "compact"). Hoist it here so the always-on log can record
# *why* a session is starting — without that, a second SessionStart
# fired ~1 min after the first looks like a Claude Code bug, when in
# fact it's the post-compact restart signal.
SOURCE=""
if [ "$HOOK_EVENT" = "SessionStart" ]; then
    SOURCE=$(extract_field source)
fi

# `tool_name` ships on PreToolUse / PostToolUse / PostToolUseFailure
# payloads. Hoist it once so the case branches don't each call
# extract_field redundantly.
TOOL_NAME=""
case "$HOOK_EVENT" in
    PreToolUse|PostToolUse|PostToolUseFailure)
        TOOL_NAME=$(extract_field tool_name)
        ;;
esac

# Always-on event log. One line per invocation. Used to confirm that
# Claude is actually calling us for the events we care about — without
# this, "no -busy markers" is indistinguishable from "hook never ran".
# Cheap (single append, no fsync) and self-rotating below.
log_event() {
    local extra=""
    [ -n "$SOURCE" ] && extra=" source=$SOURCE"
    printf "[%s] event=%-22s sid=%s ppid=%s pid=%s cwd=%s%s\n" \
        "$(date "+%Y-%m-%d %H:%M:%S")" \
        "$HOOK_EVENT" \
        "${SESSION_ID:--}" \
        "$PPID" \
        "${CLAUDE_PID:--}" \
        "${CWD:--}" \
        "$extra" >>"$HOOK_LOG" 2>/dev/null || true
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
        ESC_SOURCE=$(printf '%s' "$SOURCE" | sed 's/\\/\\\\/g; s/"/\\"/g')
        atomic_write "$STATE_DIR/$KEY-info" \
            "{\"session_id\": \"$ESC_SID\", \"pid\": $CLAUDE_PID, \"cwd\": \"$ESC_CWD\", \"started_at\": $TIMESTAMP, \"source\": \"$ESC_SOURCE\"}"
        ;;
    SessionEnd)
        rm -f "$STATE_DIR/$KEY-info" "$STATE_DIR/$KEY-busy" "$STATE_DIR/$KEY-error" "$STATE_DIR/$KEY-subagent" "$STATE_DIR/$KEY-tool" "$EVENTS_DIR/$KEY.json"
        ;;
    PermissionRequest)
        atomic_write "$EVENTS_DIR/$KEY.json" \
            "{\"session_id\": \"$ESC_SID\", \"pid\": $CLAUDE_PID, \"cwd\": \"$ESC_CWD\", \"event\": \"$HOOK_EVENT\", \"timestamp\": $TIMESTAMP}"
        ;;
    PermissionDenied)
        # User denied the permission prompt — the attention flag is no
        # longer relevant for this tool call. Claude may try a different
        # approach (which could fire another PermissionRequest), give up
        # and respond with text, or end the turn. Either way, the
        # current attention event is resolved and should drop from the
        # Clyde UI immediately rather than lingering until the next
        # PreToolUse or Stop.
        rm -f "$EVENTS_DIR/$KEY.json"
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
        # Clear busy, error, subagent, tool, and attention markers. Stop
        # means the turn is over — everything from that turn is resolved.
        rm -f "$STATE_DIR/$KEY-busy" "$STATE_DIR/$KEY-error" "$STATE_DIR/$KEY-subagent" "$STATE_DIR/$KEY-tool" "$EVENTS_DIR/$KEY.json"
        ;;
    StopFailure)
        # API/billing/rate-limit error. Extract stop_reason so Clyde
        # can surface it in the UI ("Rate limited", "Server error",
        # etc.). The busy marker stays — Claude may retry internally
        # — but we write an error file so the UI shows *why* the
        # session is stuck.
        STOP_REASON=$(extract_field stop_reason)
        if [ -n "$STOP_REASON" ]; then
            ESC_REASON=$(printf '%s' "$STOP_REASON" | sed 's/\\/\\\\/g; s/"/\\"/g')
            atomic_write "$STATE_DIR/$KEY-error" \
                "{\"session_id\": \"$ESC_SID\", \"pid\": $CLAUDE_PID, \"reason\": \"$ESC_REASON\", \"timestamp\": $TIMESTAMP}"
        fi
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
        # The tool call itself has terminated either way (interrupt or
        # error), so the active-tool indicator must clear.
        rm -f "$STATE_DIR/$KEY-tool"
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
        # Capture which tool is now running and a short summary of its
        # primary input field. Clyde renders this on the session row so
        # the user sees "Edit · SessionRow.swift" instead of just the
        # busy spinner. Empty TOOL_NAME would only happen for malformed
        # payloads — skip the write rather than producing a junk file.
        if [ -n "$TOOL_NAME" ]; then
            ESC_TOOL=$(printf '%s' "$TOOL_NAME" | sed 's/\\/\\\\/g; s/"/\\"/g')
            TOOL_SUMMARY=$(compute_tool_summary "$TOOL_NAME")
            ESC_SUMMARY=$(printf '%s' "$TOOL_SUMMARY" | sed 's/\\/\\\\/g; s/"/\\"/g')
            atomic_write "$STATE_DIR/$KEY-tool" \
                "{\"session_id\": \"$ESC_SID\", \"pid\": $CLAUDE_PID, \"tool_name\": \"$ESC_TOOL\", \"summary\": \"$ESC_SUMMARY\", \"started_at\": $TIMESTAMP}"
        fi
        ;;
    PostToolUse)
        # Tool finished cleanly. Drop the active-tool indicator; the
        # session row will slide back to the project path until the
        # next PreToolUse fires.
        rm -f "$STATE_DIR/$KEY-tool"
        ;;
    CwdChanged)
        # User changed directory mid-session. Rewrite -info with the
        # new cwd so Clyde's project name display stays current.
        if [ -f "$STATE_DIR/$KEY-info" ] && [ -n "$CWD" ]; then
            atomic_write "$STATE_DIR/$KEY-info" \
                "{\"session_id\": \"$ESC_SID\", \"pid\": $CLAUDE_PID, \"cwd\": \"$ESC_CWD\", \"started_at\": $TIMESTAMP}"
        fi
        ;;
    Elicitation)
        # MCP tool is requesting user input (form/dialog). Treat the
        # same as PermissionRequest — write an attention event file.
        atomic_write "$EVENTS_DIR/$KEY.json" \
            "{\"session_id\": \"$ESC_SID\", \"pid\": $CLAUDE_PID, \"cwd\": \"$ESC_CWD\", \"event\": \"$HOOK_EVENT\", \"timestamp\": $TIMESTAMP}"
        ;;
    ElicitationResult)
        # User answered the MCP input form. Clear attention, same as
        # PermissionDenied does for permission prompts.
        rm -f "$EVENTS_DIR/$KEY.json"
        ;;
    SubagentStart)
        # Claude spawned a subagent. Write a marker so Clyde can
        # surface "Working (subagent: Explore)" or similar.
        AGENT_TYPE=$(extract_field agent_type)
        ESC_AGENT=$(printf '%s' "$AGENT_TYPE" | sed 's/\\/\\\\/g; s/"/\\"/g')
        atomic_write "$STATE_DIR/$KEY-subagent" \
            "{\"session_id\": \"$ESC_SID\", \"pid\": $CLAUDE_PID, \"agent_type\": \"$ESC_AGENT\", \"timestamp\": $TIMESTAMP}"
        ;;
    SubagentStop)
        rm -f "$STATE_DIR/$KEY-subagent"
        ;;
    Notification|PreCompact|PostCompact)
        # Log-only events. The always-on event log at the top of this
        # script captures them for diagnostics. Future versions may
        # add state files for richer UI (e.g. "Compacting..." badge).
        :
        ;;
esac

exit 0
