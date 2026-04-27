#!/usr/bin/env python3
"""Convert a CHANGELOG section to HTML for Sparkle's update dialog.

Sparkle renders the appcast `<description>` payload through WebKit, so
emitting a small HTML subset (paragraphs, headings, lists, bold, links)
makes the update dialog format properly instead of showing literal
markdown punctuation.

Only handles what Clyde's CHANGELOG actually uses:
  - paragraphs separated by blank lines
  - "## heading" / "### heading" (h2..h6)
  - "- item" lists with optional 2-space soft-wrap continuations
  - **bold**
  - [text](url) links

stdin -> stdout. Pure stdlib, no third-party deps.
"""

from __future__ import annotations

import html
import re
import sys
from typing import List


_HEADING_RE = re.compile(r"^(#{2,6})\s+(.*)$")
_LIST_ITEM_RE = re.compile(r"^- (.*)$")
_BOLD_RE = re.compile(r"\*\*([^*]+)\*\*")
_CODE_RE = re.compile(r"`([^`]+)`")
_LINK_RE = re.compile(r"\[([^\]]+)\]\(([^)]+)\)")


def _inline(text: str) -> str:
    out = html.escape(text, quote=False)
    out = _LINK_RE.sub(lambda m: f'<a href="{html.escape(m.group(2), quote=True)}">{m.group(1)}</a>', out)
    out = _BOLD_RE.sub(r"<strong>\1</strong>", out)
    out = _CODE_RE.sub(r"<code>\1</code>", out)
    return out


def convert(md: str) -> str:
    lines = md.splitlines()
    blocks: List[str] = []
    i = 0
    n = len(lines)

    while i < n:
        line = lines[i]

        if not line.strip():
            i += 1
            continue

        m = _HEADING_RE.match(line)
        if m:
            level = len(m.group(1))
            blocks.append(f"<h{level}>{_inline(m.group(2).strip())}</h{level}>")
            i += 1
            continue

        if _LIST_ITEM_RE.match(line):
            items: List[str] = []
            while i < n:
                cur = lines[i]
                lm = _LIST_ITEM_RE.match(cur)
                if lm:
                    items.append(lm.group(1).strip())
                    i += 1
                    continue
                if cur.startswith("  ") and cur.strip():
                    items[-1] += " " + cur.strip()
                    i += 1
                    continue
                break
            rendered = "".join(f"<li>{_inline(it)}</li>" for it in items)
            blocks.append(f"<ul>{rendered}</ul>")
            continue

        para: List[str] = [line.strip()]
        i += 1
        while i < n:
            cur = lines[i]
            if not cur.strip():
                break
            if _HEADING_RE.match(cur) or _LIST_ITEM_RE.match(cur):
                break
            para.append(cur.strip())
            i += 1
        blocks.append(f"<p>{_inline(' '.join(para))}</p>")

    return "\n".join(blocks)


if __name__ == "__main__":
    sys.stdout.write(convert(sys.stdin.read()))
