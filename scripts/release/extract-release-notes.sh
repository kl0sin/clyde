#!/usr/bin/env bash
# Print the CHANGELOG.md section for a given version to stdout.
#
# Used by:
#   - the release workflow, to populate the GitHub Release `body_path`
#     so the published release matches the CHANGELOG entry instead of
#     the bare commit list `generate_release_notes` would produce.
#   - manually, when copy-pasting notes elsewhere.
#
# Usage:
#   scripts/release/extract-release-notes.sh 0.2.3
#
# CHANGELOG.md follows Keep a Changelog: headings look like
# `## [0.2.3] — 2026-04-29`, so we match the bracketed version prefix
# at column 1.
set -euo pipefail

VERSION="${1:?usage: $0 VERSION}"
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHANGELOG="$PROJECT_ROOT/CHANGELOG.md"

# Pull every line between this version's heading and the next `## ` heading.
RAW="$(awk -v version="## [$VERSION]" '
    $0 ~ "^## " { if (printing) exit; if (index($0, version)==1) { printing=1; next } }
    printing { print }
' "$CHANGELOG")"

# Strip leading + trailing blank lines so the rendered body has no
# awkward whitespace at the top or bottom.
printf '%s' "$RAW" | awk '
    NF { found=1 }
    found { lines[++n]=$0 }
    END {
        last=n
        while (last>0 && lines[last] ~ /^[[:space:]]*$/) last--
        for (i=1; i<=last; i++) print lines[i]
    }
'
