#!/usr/bin/env bash
# Sample Clyde's memory, descriptors and threads over a long run.
#
# The short stress runs in a working session prove there is no leak
# proportional to activity. They cannot prove there is no slow drift —
# a few hundred kilobytes a day hides easily inside AppKit and only
# shows up on a machine that is never rebooted, which is how this app
# is actually used.
#
# Usage:
#   scripts/dev/memory-watch.sh [interval_seconds] [output_csv]
#
# Leave it running for a day, then:
#   scripts/dev/memory-watch.sh report <output_csv>
set -uo pipefail

OUT="${2:-${TMPDIR:-/tmp}/clyde-memory-watch.csv}"

if [ "${1:-}" = "report" ]; then
    FILE="${2:?usage: $0 report FILE}"
    python3 - "$FILE" <<'PY'
import sys, csv
rows = [r for r in csv.DictReader(open(sys.argv[1])) if r["rss_kb"]]
if len(rows) < 2:
    print("not enough samples yet"); raise SystemExit
first, last = rows[0], rows[-1]
hours = (int(last["epoch"]) - int(first["epoch"])) / 3600
rss = [int(r["rss_kb"]) for r in rows]
print(f"samples:      {len(rows)} over {hours:.1f} h")
print(f"RSS start:    {rss[0]/1024:.1f} MB")
print(f"RSS end:      {rss[-1]/1024:.1f} MB")
print(f"RSS min/max:  {min(rss)/1024:.1f} / {max(rss)/1024:.1f} MB")
# A drift figure from a short window is worse than no figure: the app is
# still warming up, and extrapolating six seconds to a day reports
# gigabytes that were never there.
if hours < 2:
    print("drift:        not reported — needs at least 2 h to mean anything")
else:
    drift = (rss[-1] - rss[0]) / hours
    print(f"drift:        {drift/1024:+.2f} MB/h  ({drift*24/1024:+.1f} MB/day)")
print(f"descriptors:  {first['fds']} → {last['fds']}")
print(f"threads:      {first['threads']} → {last['threads']}")
print()
print("A flat RSS with a steady descriptor count is the pass. Descriptors")
print("climbing at all is the more urgent signal: the app dies at the limit.")
PY
    exit 0
fi

INTERVAL="${1:-300}"
[ -f "$OUT" ] || echo "epoch,rss_kb,fds,threads" > "$OUT"
echo "sampling every ${INTERVAL}s into $OUT — ^C to stop"
while true; do
    PID=$(pgrep -x Clyde | head -1)
    if [ -n "$PID" ]; then
        RSS=$(ps -o rss= -p "$PID" | tr -d ' ')
        FDS=$(lsof -p "$PID" 2>/dev/null | wc -l | tr -d ' ')
        THR=$(ps -M "$PID" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
        echo "$(date +%s),$RSS,$FDS,$THR" >> "$OUT"
    else
        # Record the gap rather than silently skipping: a restart resets
        # the baseline and any drift measured across it is meaningless.
        echo "$(date +%s),,," >> "$OUT"
    fi
    sleep "$INTERVAL"
done
