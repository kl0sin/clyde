# Compact mode — design

**Status:** design agreed, every open question settled. Ready to plan.

**Phase:** v0.9.0

**Mockup:** every panel below was drawn at 1:1 in Clyde's own palette before this was written — https://claude.ai/code/artifact/f7eea386-55f2-4a38-9c3b-8c2b6bafd36b

## What this is

Clyde has three ways to sit on a screen: a menu-bar icon, a 130×46 widget, and a 400×420 panel. The panel is the only one that shows sessions, and it is built to be opened, read and closed — a header, an Activity trail and a summary bar take 168 of its 420 points. Compact mode is the fourth: the session rows, and nothing else, small enough to leave open beside the work it is reporting on.

## Decisions

**400 points wide, same as the full panel.** Switching modes then never moves the window, which is where the reverted resize attempt went wrong. A narrower rail at 268 points, one line per session, was drawn and dropped as too minimal to justify a second row layout.

**Rows are 30 points, down from 44.** The second line and the numbered slot go; the status, the name, the worktree badge, the agent count and the elapsed time stay on one line. Four sessions cost 160 points against 420 today. A 24-point row was drawn and rejected: 8 points of padding is too little for a row that is clickable and draggable.

**Height follows the session count**, capped by a setting (default 4). Over the cap, the oldest idle sessions drop off — never the working ones, and never one that is waiting on an answer.

**Order: needs-you, then working, then idle by most recent.** An earlier draft of this spec put working first; that was wrong. A session waiting on you is the only one that requires anything — a working session needs nothing and is there to be glanced at. In a panel kept open beside the work, the thing to act on belongs at the top.

**Agents are a count, not a list**, with their own mark — a small head with two eyes, from the mascot's family — so `4` is unmistakably four agents. Names remain in the full panel.

**The widget stays, in every mode.** This spec first said compact would replace it, reasoning that two always-on-top surfaces listing the same sessions is one too many. Tried, and wrong: the widget is not a second status display, it is the anchor the panel positions itself against and the handle the whole thing is dragged by. With it gone, compact floated with nothing to attach to — visibly detached the moment the mode changed. Only the user's own widget setting decides whether it is shown.

**A mode change re-anchors the panel.** The panel hangs off the widget, so changing its height moves the edge that hangs. Switching modes recomputes the position the same way opening it does, or the panel stays where the other mode had put it.

**Mode and position persist.** Clyde reopens as it was left. ⌃⌘C toggles whichever mode was last used, so the shortcut keeps meaning "show me Clyde".

## The status indicator

The coloured dot is replaced by four pixels — the mascot's world without its face, since a face carries character and not state. It is the same object in all three states, which is what makes a column of rows scannable:

- **Working** — light travels the grid clockwise, each pixel easing up as its neighbour is already rising. The cycle is exactly four delay steps long, so the fourth pixel hands off to the first and the wave never rests between laps.
- **Idle** — the same four pixels at rest, dim.
- **Needs you** — the wave stops and the square fills solid. It pulses three times on arrival, then holds.

Colours come from `SessionTheme`: `processingColor` for working, `readyColor` for idle, `attentionColor` for needs-you. The first draft of this design invented an amber for attention, which was wrong — that state already has a colour, used everywhere else in the app.

**Attention deliberately stops moving.** Working motion is ambient and meant to be ignorable; attention wants to be noticed once and then stay legible while it is dealt with. An indicator that keeps flashing until you act is the pattern everybody mutes. And the state that remains is a shape — filled versus travelling versus at rest reads with the colour removed.

The same indicator carries into the full panel's slot: a working session shows the wave where the mascot is today (the mascot says "Clyde", which every row already is), and an idle one keeps today's grey box and session number.

**Motion rules, in all modes.** Working rows only. Stopped when the panel is hidden. Off entirely under reduced motion, where shape and colour already carry the state. Only `opacity` and `transform` animate — the two properties that do not touch layout — and the cycle stays under one hertz, because this window is meant to stay open and an animation that runs forever costs battery.

## Permission requests in compact

**The row expands for the length of the decision window, then collapses.** The alternative — deferring to the terminal — produces the worst combination available: the user switched the feature on, keeps compact open, and it does not work in the mode they are looking at.

One request is expanded at a time, the newest; others wait collapsed. The command is never abbreviated to make it fit: it wraps and folds behind *Show all N lines*, exactly as in the full panel, for the same reason — a shortened command invites approving what was not read.

This is the only moment compact changes its own height. That has to go through the same door as every other size change: the panel refuses any size its content asks for, so compact computes a height from what it is showing and applies it deliberately. Growing downward keeps the top edge still.

## Risks worth naming before building

**The panel is a fixed surface and much depends on it.** The reverted attempt at a resizable panel broke the widget anchor, the slide animation and the drag regions — none of which were in scope at the time, and none of which had tests. Compact changes the same window's size on every session change, so the anchor maths, the show/hide animation and the drag strip are in scope from the start.

**A working session with a request open is compact at its tallest.** Four sessions, one expanded request, and the mode is no longer obviously smaller than the panel it replaced. The cap on rows and the one-request-at-a-time rule are what keep that bounded.

## How this is verified

Unit tests cover the height calculation, the ordering and cap, and the indicator's state mapping. None of that is the real check.

The real check is live: compact open beside a terminal while sessions start, work, finish and ask for permission, watched for long enough to see whether the motion is ignorable or irritating. Two of this project's shipped UI defects — a panel three times its height, and a command that read as truncated — were found by looking at the thing rather than by a test, and both would have passed a green suite.
