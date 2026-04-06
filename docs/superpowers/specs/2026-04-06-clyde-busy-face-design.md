# Clyde "Busy Face" — Design

**Date:** 2026-04-06
**Status:** Approved
**Scope:** `Clyde/Views/ClydeAnimationView.swift`

## Goal

In `busy` state, replace Clyde's full body sprite with a close-up of his working face, so the user can identify with the robot and read his emotion at a glance. The widget frame stays the same size (22×22 pt in `WidgetView`).

Chosen concept: **C1 — Face + terminal bar**.

## Visual Specification

### Sprite: `busyFace` (16×16)

- The head fills the full 16×16 grid, from top to row 12.
- Antenna: rows 0–1, centered (cols 6–9), green tip pulsing.
- Head outline: dark `#14141a` border, white interior.
- Eyes: rows 5–6, two 2-wide pupils that shift horizontally each animation tick (scan ←→).
- Mouth: row 8, uses existing `mouthBusy` 3-frame animation (open / half / closed).
- Rows 12–13: head bottom + chin shadow.
- Rows 14–15: **terminal bar**.

### Terminal bar

- Background: `#0d2030` (near-black, cold).
- Foreground glyphs: `#59ffb3` at ~40% opacity (soft, peripheral).
- Buffer: 16 cells × 2 rows. Each cell holds one of: `•` (dot), `-` (dash), empty.
- Scroll: shifts left by 1 cell every ~0.2 s; a new random cell enters from the right.
- Random distribution: ~35% dot, ~25% dash, ~40% empty (sparse, readable).

## Behavior

### State transitions (crossfade)

- `idle`/`sleeping` → `busy`: fade the body sprite out and the face sprite in simultaneously over **250 ms**, `.easeInOut`.
- `busy` → `idle`/`sleeping`: reverse.
- Implementation: two `Canvas` layers in a `ZStack`; each has an `opacity` driven by `@State` toggled in `onChange(of: state)` inside `withAnimation(.easeInOut(duration: 0.25))`.
- Animation loops (eye scan, mouth, terminal bar) run unconditionally on the face layer; when `opacity == 0` they are invisible but cheap.

### Animations in busy mode

| Element | Animation | Period |
|---|---|---|
| Eye pupils | Scan ←→ (positions: -1, 0, +1, 0 px relative) | ~0.4 s per step |
| Eye blink | Full close for 1 tick | Every ~6 s |
| Mouth | Existing `mouthBusy` 3-frame loop | ~0.9 s cycle |
| Antenna tip | Green pulse (existing `antennaGlow`) | ~0.6 s |
| Terminal bar | Shift left 1 cell, push random cell right | ~0.2 s |

## Architecture

### Files touched

- `Clyde/Views/ClydeAnimationView.swift` — only file that changes.
  - Add `ClydeSprite.busyFace: [[Color?]]`.
  - Add `@State private var terminalBuffer: [[Character]]` (2×16) initialized on appear.
  - Add `@State private var eyeScanOffset: Int` (-1/0/1).
  - Add `@State private var bodyOpacity: Double = 1` and `@State private var faceOpacity: Double = 0`.
  - Refactor `body` into `ZStack { bodyCanvas; faceCanvas }`; route existing busy-arm/antenna tweaks to the appropriate layer.
  - `onChange(of: state)` updates the opacities inside `withAnimation`.
  - Per timeline tick: advance `animationTick`, every 2 ticks shift `terminalBuffer`, every 2 ticks step `eyeScanOffset`.

### Files **not** touched

- `WidgetView.swift` — same frame, same view, same `pixelSize`.
- All other `Views/*` — unchanged.

## Testing

- Manual: toggle state via dev hook, verify crossfade is smooth, no flicker, no layout jump.
- Manual: leave in busy for 30 s, confirm terminal bar doesn't stall, stays visually subtle (doesn't steal focus from eyes).
- Manual: at 22×22 render size, pupils remain readable (1 px each).

## Out of Scope

- Changing widget dimensions.
- Tying terminal bar to real session/hook data (future consideration).
- New sounds or haptics.
- Changes to `idle` or `sleeping` visuals.
