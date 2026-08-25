#!/bin/bash
# clyde-hook-version: 29
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
#   SessionEnd          → removes info + busy + error + subagent + tool + plan + event + cleans up -agents/ dir
#   UserPromptSubmit    → state/<session_id>-busy marker (+ backfill -info, drops fully-completed -plan)
#   Stop                → removes busy + error + subagent + tool + event marker
#   StopFailure         → writes state/<session_id>-error with stop_reason
#   PermissionRequest   → events/<session_id>.json (attention flag)
#   PermissionDenied    → clears event file (user denied permission)
#   PreToolUse          → clears event file + refreshes busy mtime + writes -tool; Agent/Task also → merges the description into the subagent's -agents/ record (pending-<tool_use_id>.json if SubagentStart hasn't landed yet)
#   PostToolUse         → removes -tool marker; Agent/Task also → removes an UNCLAIMED state/<session_id>-agents/pending-<tool_use_id>.json only
#   PostToolUseFailure  → removes -tool marker; Agent/Task also → removes an UNCLAIMED pending- entry; IF is_interrupt=true also removes busy + every -agents/ record (an interrupted agent never emits SubagentStop)
#   CwdChanged          → rewrites state/<session_id>-info with new cwd
#   Elicitation         → events/<session_id>.json (MCP tool input request)
#   ElicitationResult   → clears event file (MCP input answered)
#   SubagentStart       → merges with PreToolUse's record into state/<session_id>-agents/<agent_id>.json (either event may arrive first); also legacy -subagent (deprecated)
#   SubagentStop        → removes legacy -subagent + state/<session_id>-agents/<agent_id>.json (the agent outlives its dispatching tool call)
#   TeammateIdle        → flags an EXISTING state/<session_id>-agents/<agent_id>.json as idle (never creates one; not an attention signal)
#   TaskCreated         → bumps task_count in state/<session_id>-plan
#   TaskCompleted       → bumps done_count in state/<session_id>-plan (if file exists)
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
# truncated. Pure shell; bash's ${#s} and ${s:0:N} are
# character-counted in a UTF-8 locale, so this is safe for Unicode
# file paths and query strings. The 40-char cap downstream keeps
# display strings compact regardless of encoding.
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
            # Collapse embedded newlines (python3 strips them; the
            # grep fallback may not).
            raw=$(printf '%s' "$raw" | tr '\n' ' ')
            truncate_summary "$raw" 40
            ;;
        Glob|Grep)
            raw=$(extract_tool_input_field pattern)
            truncate_summary "$raw" 40
            ;;
        Agent|Task)
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

# Read a numeric field from the existing -plan file (if any). Returns
# 0 if the file is missing, the key is absent, or python3 fails. Uses
# python3 because hand-parsing arbitrary-order JSON keys in shell is
# fragile (the existing extract_field grep fallback works because
# Claude's payloads have predictable shapes, but our own state files
# could be re-ordered by a future hook revision).
read_plan_field() {
    local key=$1
    local plan_file="$STATE_DIR/$KEY-plan"
    if [ ! -f "$plan_file" ]; then
        printf '0'
        return
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        # python3 missing — best-effort grep for the key. Acceptable
        # because we only emit integer values for these keys, no
        # quoting / escaping concerns.
        local value
        value=$(grep -o "\"$key\"[[:space:]]*:[[:space:]]*[0-9]*" "$plan_file" 2>/dev/null \
            | head -n1 \
            | sed -E 's/.*:[[:space:]]*([0-9]+)/\1/')
        printf '%s' "${value:-0}"
        return
    fi
    python3 -c "
import json, sys
try:
    with open('$plan_file') as f:
        d = json.load(f)
    v = d.get('$key', 0)
    print(int(v) if isinstance(v, (int, float)) else 0)
except Exception:
    print(0)
" 2>/dev/null || printf '0'
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

# `tool_name` and `tool_use_id` ship on PreToolUse / PostToolUse / PostToolUseFailure
# payloads. Hoist them once so the case branches don't each call
# extract_field redundantly.
TOOL_NAME=""
TOOL_USE_ID=""
case "$HOOK_EVENT" in
    PreToolUse|PostToolUse|PostToolUseFailure)
        TOOL_NAME=$(extract_field tool_name)
        TOOL_USE_ID=$(extract_field tool_use_id)
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

# Cleat (https://github.com/cleatdev/cleat) runs Claude Code inside a
# Docker container and forwards hook events to host-side hook commands
# via a bash function (`_hook_bridge_watcher`) in `bin/cleat`.
#
# Two host signals are available when our hook fires from cleat:
#   1. The cleat shell process itself sits in our PPID chain — it has
#      a real macOS PID and its working directory (via lsof -d cwd) is
#      the host project root mounted to /workspace inside the container.
#   2. `docker ps --filter name=cleat-` lists running containers; we
#      match by `/workspace` mount Source to find which one owns this
#      cleat process, recovering the canonical container name.
#
# We deliberately do NOT use `docker inspect .State.Pid` for the
# session's anchor PID, even though it's the obvious choice. On macOS,
# Docker Desktop runs containers inside a Linux VM, so .State.Pid is
# in the VM's PID namespace — `kill -0 <that_pid>` from macOS returns
# ESRCH (or worse, hits an unrelated Mac process). Using the cleat
# shell PID instead gives us a real host-namespace PID that liveness
# probes can reach. When the user closes their cleat terminal, that
# PID dies and Clyde correctly ages the session out.
#
# Without this remapping, hook events from cleat are unusable: `cwd`
# arrives as `/workspace`, `pid` is container-namespaced, and
# find_claude_pid can't locate a `claude` ancestor because Claude
# lives inside the container.

# Walks the PPID chain looking for the cleat shell process. Sets
# CLEAT_HOST_CWD (the cleat process's working directory = host project
# root) and CLEAT_HOST_PID (the cleat process's real macOS PID).
# Returns 0 on match, 1 otherwise.
detect_cleat_host_process() {
    CLEAT_HOST_CWD=""
    CLEAT_HOST_PID=""
    # Walk PPID upward, keeping the topmost ancestor whose argv looks
    # like the cleat script. Why "topmost":
    #
    # Cleat's hook bridge runs the user's hook commands via
    #     ( _execute_host_hooks "$event_json" "${settings_files[@]}" ) &
    # inside `_execute_host_hook_bg`, itself called from the
    # `_hook_bridge_watcher` function backgrounded with &. Both
    # subshells fork off bash processes that *inherit cleat's argv*
    # (bash doesn't rewrite argv when entering `( ... )` or `func &`),
    # so any of them passes our `basename == cleat` test. But these
    # subshells are transient — `_execute_host_hook_bg` is forked
    # per hook event and exits within milliseconds, so its PID is
    # unsafe to record (`kill -0` will fail by the next poll, and
    # Clyde would mark the session as dead immediately).
    #
    # The cleat *main* script process at the top of the chain IS
    # long-lived — it's the user's interactive shell session that
    # owns the container. Its parent is the user's terminal, which
    # does NOT match. So we walk all the way up, and the deepest
    # cleat-matching pid is the real anchor.
    local pid=$PPID
    local depth=0
    local last_cleat_pid=""
    while [ "$pid" -gt 1 ] && [ "$depth" -lt 20 ]; do
        # `ww` defeats macOS's default argv truncation.
        local args
        args=$(ps -ww -p "$pid" -o args= 2>/dev/null)
        # cleat may be invoked as `cleat …`, `/usr/local/bin/cleat …`,
        # or `/bin/bash /path/to/cleat …` (shebang form on macOS). In
        # all cases either argv[0] or argv[1]'s basename is "cleat".
        local first second
        # shellcheck disable=SC2086
        set -- $args
        first=${1:-}
        second=${2:-}
        if [ "$(basename -- "$first" 2>/dev/null)" = cleat ] \
           || [ "$(basename -- "$second" 2>/dev/null)" = cleat ]; then
            last_cleat_pid=$pid
        elif [ -n "$last_cleat_pid" ]; then
            # We left the cleat-matching segment of the chain — the
            # previous pid was the topmost cleat ancestor. Stop here so
            # we don't keep climbing into the user's terminal.
            break
        fi
        pid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ')
        depth=$((depth + 1))
    done

    if [ -n "$last_cleat_pid" ]; then
        local cwd
        cwd=$(lsof -a -p "$last_cleat_pid" -d cwd -Fn 2>/dev/null \
              | awk '/^n/{print substr($0,2); exit}')
        if [ -n "$cwd" ] && [ "$cwd" != "/" ]; then
            CLEAT_HOST_CWD=$cwd
            CLEAT_HOST_PID=$last_cleat_pid
            return 0
        fi
    fi
    return 1
}

# Given the host path that maps to /workspace, find the matching cleat
# container name via `docker ps` + mount Source comparison. Sets
# CLEAT_CNAME and CLEAT_HOST_WORKSPACE (the docker-reported Source,
# may differ from the lsof cwd by symlink resolution).
#
# Cached at /tmp/.clyde-cleat-<sha-of-path> so subsequent events skip
# the ~100-300ms docker probe. Cache holds cname + cleat_pid +
# workspace; entry is invalidated whenever the cached cleat PID is no
# longer alive (covers `cleat stop`, terminal close, etc.) — at that
# point we re-probe docker. The cleat_pid stored in the cache is the
# host-process PID passed in via $2; we use it solely as a liveness
# token, not for any subsequent operation.
resolve_cleat_cname() {
    local target=$1
    local cleat_pid=$2
    CLEAT_CNAME=""
    CLEAT_HOST_WORKSPACE=""

    local key
    if command -v shasum >/dev/null 2>&1; then
        key=$(printf '%s' "$target" | shasum -a 1 | awk '{print $1}')
    else
        key=$(printf '%s' "$target" | tr '/' '_' | tr -dc '[:alnum:]_-' | cut -c1-40)
    fi
    local cache_file="/tmp/.clyde-cleat-${key}"

    # GC stale cache files. macOS doesn't periodically prune /tmp, so
    # entries for projects the user hasn't reopened in a week sit there
    # forever otherwise. Done here (not at script top) because cache
    # files only matter inside this resolver. Errors swallowed — this
    # is best-effort cleanup, never blocks the real work.
    find /tmp -maxdepth 1 -name '.clyde-cleat-*' -type f -mtime +7 -delete 2>/dev/null || true

    if [ -f "$cache_file" ]; then
        local cached cname cached_pid path
        cached=$(cat "$cache_file" 2>/dev/null)
        cname=$(printf '%s' "$cached" | awk -F'\t' '{print $1}')
        cached_pid=$(printf '%s' "$cached" | awk -F'\t' '{print $2}')
        path=$(printf '%s' "$cached" | awk -F'\t' '{print $3}')
        if [ -n "$cname" ] && [ -n "$cached_pid" ] \
           && kill -0 "$cached_pid" 2>/dev/null \
           && [ "$path" = "$target" ]; then
            CLEAT_CNAME=$cname
            CLEAT_HOST_WORKSPACE=$path
            return 0
        fi
    fi

    command -v docker >/dev/null 2>&1 || return 1
    local names
    names=$(docker ps --filter "name=cleat-" --format '{{.Names}}' 2>/dev/null)
    [ -n "$names" ] || return 1

    local target_real
    target_real=$(cd "$target" 2>/dev/null && pwd -P) || target_real=$target

    local cname src src_real
    while IFS= read -r cname; do
        [ -n "$cname" ] || continue
        src=$(docker inspect --format \
              '{{range .Mounts}}{{if eq .Destination "/workspace"}}{{.Source}}{{end}}{{end}}' \
              "$cname" 2>/dev/null)
        [ -n "$src" ] || continue
        src_real=$(cd "$src" 2>/dev/null && pwd -P) || src_real=$src
        if [ "$src" = "$target" ] || [ "$src_real" = "$target_real" ] \
           || [ "$src" = "$target_real" ] || [ "$src_real" = "$target" ]; then
            printf '%s\t%s\t%s\n' "$cname" "$cleat_pid" "$target" >"$cache_file" 2>/dev/null || true
            CLEAT_CNAME=$cname
            CLEAT_HOST_WORKSPACE=$src
            return 0
        fi
    done <<< "$names"
    return 1
}

# Detect cleat *before* find_claude_pid: in cleat-land there is no
# `claude` ancestor on the host (claude lives in the container), so
# find_claude_pid would just fall through and produce a `WARN no claude
# ancestor` log line, masking the real story.
CLEAT_CNAME=""
CLEAT_RUNTIME=""
CLEAT_HOST_CWD=""
CLEAT_HOST_PID=""
CLEAT_HOST_WORKSPACE=""
if detect_cleat_host_process; then
    if resolve_cleat_cname "$CLEAT_HOST_CWD" "$CLEAT_HOST_PID"; then
        CLEAT_RUNTIME="cleat"
        # CLEAT_HOST_PID is the cleat shell process PID — a real macOS PID
        # that `kill -0` can probe. Storing it as CLAUDE_PID lets Clyde's
        # liveness check work without special-casing the container init
        # PID (which lives in the Docker VM's namespace).
        CLAUDE_PID=$CLEAT_HOST_PID
        # Container cwd of `/workspace[/sub/path]` maps to
        # `<host_workspace>[/sub/path]`. Anything outside /workspace is
        # left alone — could happen if the user `cd`s out of the bind
        # mount, but Clyde would show that path verbatim anyway.
        case "$CWD" in
            /workspace)     CWD=$CLEAT_HOST_WORKSPACE ;;
            /workspace/*)   CWD="$CLEAT_HOST_WORKSPACE/${CWD#/workspace/}" ;;
        esac
    else
        # PPID walk found a cleat process but `docker ps` / mount-source
        # match didn't produce a container name. Common causes: docker
        # daemon down, `--cap hooks` not enabled (so the bridge that
        # invoked us is from an older cleat snapshot), or the mount path
        # differs from what lsof reports (symlink chains we can't
        # normalise). Log so the user has a breadcrumb instead of a bare
        # "no claude ancestor" — that warning is misleading here.
        printf "[%s] cleat detected (pid=%s cwd=%s) but docker lookup failed for event=%s\n" \
            "$(date "+%Y-%m-%d %H:%M:%S")" "$CLEAT_HOST_PID" "$CLEAT_HOST_CWD" "$HOOK_EVENT" \
            >>"$HOOK_LOG" 2>/dev/null || true
        CLAUDE_PID=$(find_claude_pid || echo "")
    fi
else
    CLAUDE_PID=$(find_claude_pid || echo "")
fi
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

# Optional runtime-suffix for -info JSON. Empty for regular host
# sessions so the existing on-disk format is byte-identical. Cleat
# sessions get `"runtime": "cleat", "container": "<cname>"` appended
# inside the object, which Clyde uses to (a) relax its liveness check
# (cleat sessions point at the docker init PID, which isn't named
# "claude") and (b) decorate the row with a "cleat" badge.
INFO_RUNTIME_FIELDS=""
if [ -n "$CLEAT_RUNTIME" ]; then
    ESC_CONTAINER=$(printf '%s' "$CLEAT_CNAME" | sed 's/\\/\\\\/g; s/"/\\"/g')
    INFO_RUNTIME_FIELDS=", \"runtime\": \"$CLEAT_RUNTIME\", \"container\": \"$ESC_CONTAINER\""
fi

# Atomic write helper: stage to a temp file in the same dir, then mv.
atomic_write() {
    local target=$1
    local body=$2
    local tmp
    tmp=$(mktemp "$(dirname "$target")/.clyde-tmp.XXXXXX") || return 1
    printf '%s\n' "$body" > "$tmp"
    mv -f "$tmp" "$target"
}

# --- Subagent record merging -------------------------------------------
#
# A running subagent is described by two hook events that share NO
# identifier: PreToolUse(Agent) carries tool_use_id and the description,
# SubagentStart carries agent_id and agent_type. Claude fires them as
# separate processes with no ordering guarantee, and measurements show
# the PreToolUse hook is the slower of the two (it probes cleat and
# shells out to lsof), so SubagentStart frequently runs FIRST.
#
# So the merge is symmetric: whichever event arrives second completes
# the record the first one opened, correlating on agent type and taking
# the oldest unmatched candidate. The record always ends up keyed on
# agent_id, which is what SubagentStop tears down.
#
# Both directions are a read-modify-write over a shared directory, so
# they run under an mkdir-based lock — mkdir is atomic on every POSIX
# filesystem and needs no cleanup beyond rmdir. The wait is bounded and
# the hook proceeds regardless: never block Claude, ever.
AGENTS_LOCK=""

acquire_agents_lock() {
    local dir="$STATE_DIR/$KEY-agents"
    mkdir -p "$dir" 2>/dev/null || return 1
    local lock="$dir/.claim.lock"
    local i=0
    while [ "$i" -lt 50 ]; do
        if mkdir "$lock" 2>/dev/null; then
            AGENTS_LOCK="$lock"
            return 0
        fi
        # A hook that died holding the lock would wedge every later one.
        # Anything older than a minute is by definition abandoned.
        if [ -d "$lock" ] && [ -z "$(find "$lock" -maxdepth 0 -mmin -1 2>/dev/null)" ]; then
            rmdir "$lock" 2>/dev/null
        fi
        sleep 0.01
        i=$((i + 1))
    done
    return 1
}

release_agents_lock() {
    [ -n "$AGENTS_LOCK" ] && rmdir "$AGENTS_LOCK" 2>/dev/null
    AGENTS_LOCK=""
}

# merge_agent_record <mode> <id> <type> <summary>
#   mode=start : id is agent_id  — adopt a pending- entry of this type,
#                or open a record awaiting its description.
#   mode=pre   : id is tool_use_id — fill the description into a record
#                SubagentStart already opened, or write pending-<id>.
#   mode=idle  : id is agent_id — flag an EXISTING record as idle. Never
#                creates one; returns non-zero when there is nothing to
#                annotate.
merge_agent_record() {
    command -v python3 >/dev/null 2>&1 || return 1
    acquire_agents_lock || return 1
    MERGE_MODE=$1 MERGE_ID=$2 MERGE_TYPE=$3 MERGE_SUMMARY=$4 \
    MERGE_DIR="$STATE_DIR/$KEY-agents" MERGE_SID="$SESSION_ID" \
    MERGE_PID="$CLAUDE_PID" MERGE_TS="$TIMESTAMP" python3 -c "
import json, os, glob, tempfile

d = os.environ['MERGE_DIR']
mode = os.environ['MERGE_MODE']
ident = os.environ['MERGE_ID']
atype = os.environ['MERGE_TYPE']
summary = os.environ['MERGE_SUMMARY']
ts = int(os.environ['MERGE_TS'] or 0)

def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return None

def save(path, rec):
    fd, tmp = tempfile.mkstemp(dir=d, prefix='.clyde-tmp.')
    with os.fdopen(fd, 'w') as f:
        json.dump(rec, f)
        f.write('\n')
    os.replace(tmp, path)

def oldest(paths, want_pending):
    best = None
    for path in paths:
        rec = load(path)
        if rec is None:
            continue
        if atype and rec.get('subagent_type') != atype:
            continue
        if want_pending is False and not rec.get('awaiting_summary'):
            continue
        started = rec.get('started_at') or 0
        if best is None or started < best[0]:
            best = (started, path, rec)
    return best

pending = sorted(glob.glob(os.path.join(d, 'pending-*.json')))
claimed = sorted(p for p in glob.glob(os.path.join(d, '*.json'))
                 if not os.path.basename(p).startswith('pending-'))

if mode == 'idle':
    # Annotate only. A teammate we never saw start gets no record —
    # inventing one from an idle notification is how phantom rows are
    # born. Exit non-zero so the caller can log it and move on.
    path = os.path.join(d, ident + '.json')
    rec = load(path)
    if rec is None:
        raise SystemExit(1)
    rec['idle'] = True
    rec['idle_at'] = ts
    save(path, rec)
elif mode == 'start':
    hit = oldest(pending, True)
    if hit:
        _, path, rec = hit
        rec['agent_id'] = ident
        rec.pop('awaiting_summary', None)
        save(os.path.join(d, ident + '.json'), rec)
        os.remove(path)
    else:
        save(os.path.join(d, ident + '.json'), {
            'session_id': os.environ['MERGE_SID'],
            'pid': int(os.environ['MERGE_PID'] or 0),
            'agent_id': ident,
            'subagent_type': atype,
            'summary': '',
            'started_at': ts,
            'awaiting_summary': True,
        })
else:
    hit = oldest(claimed, False)
    if hit:
        _, path, rec = hit
        rec['summary'] = summary
        rec['tool_use_id'] = ident
        rec.pop('awaiting_summary', None)
        save(path, rec)
    else:
        save(os.path.join(d, 'pending-' + ident + '.json'), {
            'session_id': os.environ['MERGE_SID'],
            'pid': int(os.environ['MERGE_PID'] or 0),
            'tool_use_id': ident,
            'subagent_type': atype,
            'summary': summary,
            'started_at': ts,
        })
" 2>/dev/null
    MERGE_RC=$?
    release_agents_lock
    return $MERGE_RC
}

case "$HOOK_EVENT" in
    SessionStart)
        ESC_SOURCE=$(printf '%s' "$SOURCE" | sed 's/\\/\\\\/g; s/"/\\"/g')
        atomic_write "$STATE_DIR/$KEY-info" \
            "{\"session_id\": \"$ESC_SID\", \"pid\": $CLAUDE_PID, \"cwd\": \"$ESC_CWD\", \"started_at\": $TIMESTAMP, \"source\": \"$ESC_SOURCE\"$INFO_RUNTIME_FIELDS}"
        ;;
    SessionEnd)
        rm -f "$STATE_DIR/$KEY-info" "$STATE_DIR/$KEY-busy" "$STATE_DIR/$KEY-error" "$STATE_DIR/$KEY-subagent" "$STATE_DIR/$KEY-tool" "$STATE_DIR/$KEY-plan" "$EVENTS_DIR/$KEY.json"
        rm -rf "$STATE_DIR/$KEY-agents"
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
        # User typed a reply — any attention flag from a prior
        # `Notification("waiting for your input")` is resolved. Without
        # this, the badge would linger until PreToolUse fires (could
        # be several seconds for plan-mode or pure-text turns) even
        # though Claude is already working again.
        rm -f "$EVENTS_DIR/$KEY.json"
        # If this is an existing session that predates Clyde, the
        # SessionStart hook never fired for it. Backfill -info so the
        # session "graduates" to full hook tracking from now on.
        if [ ! -f "$STATE_DIR/$KEY-info" ]; then
            atomic_write "$STATE_DIR/$KEY-info" \
                "{\"session_id\": \"$ESC_SID\", \"pid\": $CLAUDE_PID, \"cwd\": \"$ESC_CWD\", \"started_at\": $TIMESTAMP$INFO_RUNTIME_FIELDS}"
        fi
        # If the previous turn finished a plan (done_count == task_count),
        # drop the -plan marker now that the user has moved on. Partial
        # plans persist across turns so the badge keeps tracking when the
        # user types "continue".
        if [ -f "$STATE_DIR/$KEY-plan" ]; then
            PLAN_TASK_COUNT=$(read_plan_field task_count)
            PLAN_DONE_COUNT=$(read_plan_field done_count)
            if [ -n "$PLAN_TASK_COUNT" ] && [ "$PLAN_TASK_COUNT" -gt 0 ] \
               && [ "$PLAN_DONE_COUNT" = "$PLAN_TASK_COUNT" ]; then
                rm -f "$STATE_DIR/$KEY-plan"
            fi
        fi
        ;;
    Stop)
        # Clear busy, error, legacy subagent, tool, and attention markers. Stop
        # means the turn is over — everything from that turn is resolved.
        # NOTE: -agents/ is intentionally NOT cleared here. Parallel subagents
        # often outlive the parent's Stop event; each entry vanishes only when
        # its own PostToolUse(Agent) arrives.
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
            # Ctrl+C tears down every subagent in the turn, and an
            # interrupted agent never emits SubagentStop — without this
            # its record would linger as a phantom row until the
            # 30-minute GC. Leaves .claim.lock (a directory) alone.
            rm -f "$STATE_DIR/$KEY-agents"/*.json 2>/dev/null
        fi
        # The tool call itself has terminated either way (interrupt or
        # error), so the active-tool indicator must clear.
        rm -f "$STATE_DIR/$KEY-tool"
        if { [ "$TOOL_NAME" = "Agent" ] || [ "$TOOL_NAME" = "Task" ]; } && [ -n "$TOOL_USE_ID" ]; then
            # Only sweeps an entry SubagentStart never claimed. A claimed
            # entry is keyed on agent_id and belongs to SubagentStop —
            # the agent routinely outlives this tool call.
            rm -f "$STATE_DIR/$KEY-agents/pending-$TOOL_USE_ID.json"
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
        if { [ "$TOOL_NAME" = "Agent" ] || [ "$TOOL_NAME" = "Task" ]; } && [ -n "$TOOL_USE_ID" ]; then
            SUBAGENT_TYPE=$(extract_tool_input_field subagent_type)
            [ -z "$SUBAGENT_TYPE" ] && SUBAGENT_TYPE="agent"
            DESCRIPTION=$(extract_tool_input_field description)
            if [ -z "$DESCRIPTION" ]; then
                DESCRIPTION=$(extract_tool_input_field prompt | tr '\n' ' ')
                DESCRIPTION=$(truncate_summary "$DESCRIPTION" 40)
            else
                DESCRIPTION=$(truncate_summary "$DESCRIPTION" 80)
            fi
            ESC_AGENT=$(printf '%s' "$SUBAGENT_TYPE" | sed 's/\\/\\\\/g; s/"/\\"/g')
            ESC_SUMMARY=$(printf '%s' "$DESCRIPTION" | sed 's/\\/\\\\/g; s/"/\\"/g')
            ESC_TOOLID=$(printf '%s' "$TOOL_USE_ID" | sed 's/\\/\\\\/g; s/"/\\"/g')
            mkdir -p "$STATE_DIR/$KEY-agents"
            # Completes a record SubagentStart may already have opened —
            # the description arrives only here, so it has to reach the
            # record no matter which of the two events won the race.
            if ! merge_agent_record pre "$TOOL_USE_ID" "$SUBAGENT_TYPE" "$DESCRIPTION"; then
                # python3 missing — degrade to the pre-v28 shape. The
                # background-agent fix needs a real JSON parser; the
                # PostToolUse sweep below still cleans this up.
                atomic_write "$STATE_DIR/$KEY-agents/pending-$TOOL_USE_ID.json" \
                    "{\"session_id\": \"$ESC_SID\", \"tool_use_id\": \"$ESC_TOOLID\", \"subagent_type\": \"$ESC_AGENT\", \"summary\": \"$ESC_SUMMARY\", \"started_at\": $TIMESTAMP}"
            fi
        fi
        ;;
    PostToolUse)
        # Tool finished cleanly. Drop the active-tool indicator; the
        # session row will slide back to the project path until the
        # next PreToolUse fires.
        rm -f "$STATE_DIR/$KEY-tool"
        if { [ "$TOOL_NAME" = "Agent" ] || [ "$TOOL_NAME" = "Task" ]; } && [ -n "$TOOL_USE_ID" ]; then
            # Only sweeps an entry SubagentStart never claimed. A claimed
            # entry is keyed on agent_id and belongs to SubagentStop —
            # the agent routinely outlives this tool call.
            rm -f "$STATE_DIR/$KEY-agents/pending-$TOOL_USE_ID.json"
        fi
        ;;
    CwdChanged)
        # User changed directory mid-session. Rewrite -info with the
        # new cwd so Clyde's project name display stays current.
        if [ -f "$STATE_DIR/$KEY-info" ] && [ -n "$CWD" ]; then
            atomic_write "$STATE_DIR/$KEY-info" \
                "{\"session_id\": \"$ESC_SID\", \"pid\": $CLAUDE_PID, \"cwd\": \"$ESC_CWD\", \"started_at\": $TIMESTAMP$INFO_RUNTIME_FIELDS}"
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
        # The subagent is now actually running. Adopt the pending entry
        # PreToolUse(Agent) wrote so the row is keyed on the agent's own
        # identity from here on — PostToolUse can then stop deleting it.
        AGENT_ID=$(extract_field agent_id)
        AGENT_TYPE=$(extract_field agent_type)
        if [ -n "$AGENT_ID" ]; then
            merge_agent_record start "$AGENT_ID" "$AGENT_TYPE" "" || true
        fi
        ESC_AGENT=$(printf '%s' "$AGENT_TYPE" | sed 's/\\/\\\\/g; s/"/\\"/g')
        atomic_write "$STATE_DIR/$KEY-subagent" \
            "{\"session_id\": \"$ESC_SID\", \"pid\": $CLAUDE_PID, \"agent_type\": \"$ESC_AGENT\", \"timestamp\": $TIMESTAMP}"
        ;;
    SubagentStop)
        rm -f "$STATE_DIR/$KEY-subagent"
        # The agent is genuinely finished — this is the only event that
        # says so. Verified against a live session: SubagentStop carries
        # agent_id and agent_type but no tool_use_id, so the entry it
        # tears down is the one SubagentStart re-keyed under agent_id.
        SUB_AGENT_ID=$(extract_field agent_id)
        if [ -n "$SUB_AGENT_ID" ]; then
            rm -f "$STATE_DIR/$KEY-agents/$SUB_AGENT_ID.json"
        fi
        ;;
    TeammateIdle)
        # An agent-team teammate is about to go idle. TeammateIdle
        # addresses it by agent_id — the same key space the subagent
        # records already live in — so we annotate in place.
        #
        # Deliberately NOT routed into the attention pipeline. v0.5.1
        # mapped an ambiguous, attention-sounding event onto the badge on
        # the same reasoning and v0.5.2 had to revert it a day later once
        # it turned out to fire every turn. Until this event's real
        # frequency is known, idle is a quiet state on the row, not an
        # alert. Promoting it later is a one-line change; un-shipping a
        # false-positive badge is a hotfix release.
        AGENT_ID=$(extract_field agent_id)
        if [ -n "$AGENT_ID" ]; then
            merge_agent_record idle "$AGENT_ID" "" "" || true
        fi
        ;;
    TaskCreated)
        # Plan-then-execute progress. Read the existing -plan record
        # (if any) so we can increment task_count without losing
        # done_count or the original started_at. First TaskCreated
        # initializes started_at to the current timestamp.
        PLAN_TASK_COUNT=$(read_plan_field task_count)
        PLAN_DONE_COUNT=$(read_plan_field done_count)
        PLAN_STARTED_AT=$(read_plan_field started_at)
        if [ "$PLAN_STARTED_AT" -eq 0 ] 2>/dev/null; then
            PLAN_STARTED_AT=$TIMESTAMP
        fi
        PLAN_TASK_COUNT=$((PLAN_TASK_COUNT + 1))
        atomic_write "$STATE_DIR/$KEY-plan" \
            "{\"session_id\": \"$ESC_SID\", \"pid\": $CLAUDE_PID, \"task_count\": $PLAN_TASK_COUNT, \"done_count\": $PLAN_DONE_COUNT, \"started_at\": $PLAN_STARTED_AT}"
        ;;
    TaskCompleted)
        # Increment done_count only if a -plan file already exists.
        # A TaskCompleted without a prior TaskCreated would be a race
        # / lost event — fabricating a new file with done_count=1 and
        # task_count=0 would render as "1/0" in the UI, which is worse
        # than skipping silently.
        if [ -f "$STATE_DIR/$KEY-plan" ]; then
            PLAN_TASK_COUNT=$(read_plan_field task_count)
            PLAN_DONE_COUNT=$(read_plan_field done_count)
            PLAN_STARTED_AT=$(read_plan_field started_at)
            PLAN_DONE_COUNT=$((PLAN_DONE_COUNT + 1))
            atomic_write "$STATE_DIR/$KEY-plan" \
                "{\"session_id\": \"$ESC_SID\", \"pid\": $CLAUDE_PID, \"task_count\": $PLAN_TASK_COUNT, \"done_count\": $PLAN_DONE_COUNT, \"started_at\": $PLAN_STARTED_AT}"
        fi
        ;;
    Notification)
        # Claude Code fires Notification with a human-readable `message`
        # for several reasons. Most are informational (build output
        # truncation, etc.). Importantly, in bypass-permissions mode
        # (cleat's default) Claude fires
        #     "Claude is waiting for your input"
        # after *every* `Stop` — it's the idle-state marker, not an
        # attention signal. v26 mis-mapped it onto the attention event
        # file, which lit up the "Needs Input" badge after every
        # routine turn. v27 drops that string from the match.
        #
        # We still match the permission-flavoured forms:
        #     "Claude needs your permission to use <tool>"
        #     "permission to use ..."
        # In non-bypass mode some Claude builds surface a permission
        # gate via Notification instead of (or in addition to)
        # PermissionRequest. Keeping these as triggers means we won't
        # silently miss a genuine gate if that's the only signal — and
        # they don't fire in bypass mode, so they can't false-positive
        # the way "waiting for your input" did.
        NOTIFY_MSG=$(extract_field message)
        case "$NOTIFY_MSG" in
            *"needs your permission"*|*"permission to use"*)
                ESC_MSG=$(printf '%s' "$NOTIFY_MSG" | sed 's/\\/\\\\/g; s/"/\\"/g')
                atomic_write "$EVENTS_DIR/$KEY.json" \
                    "{\"session_id\": \"$ESC_SID\", \"pid\": $CLAUDE_PID, \"cwd\": \"$ESC_CWD\", \"event\": \"$HOOK_EVENT\", \"message\": \"$ESC_MSG\", \"timestamp\": $TIMESTAMP}"
                ;;
            *)
                # Idle markers and informational notifications fall
                # through to log-only. Specifically: "Claude is waiting
                # for your input" lands here in v27+.
                :
                ;;
        esac
        ;;
    PreCompact|PostCompact)
        # Log-only events. The always-on event log at the top of this
        # script captures them for diagnostics. Future versions may
        # add state files for richer UI (e.g. "Compacting..." badge).
        :
        ;;
esac

exit 0
