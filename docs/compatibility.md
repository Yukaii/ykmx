# ykwm Compatibility Matrix

This file tracks terminal/app compatibility behavior, known gaps, and concrete
repro commands. Keep this separate from `docs/plan.md` so implementation
milestones and compatibility details do not get mixed.

## Status Legend

- `working`: behavior matches expectations
- `partial`: works with limitations or visible glitches
- `broken`: not working / blocks normal usage
- `todo`: not evaluated yet

## Environment Matrix

| Host Terminal | Session Layer | Status | Notes |
|---|---|---|---|
| Ghostty | direct `ykwm` | partial | Core panes render; still tuning renderer correctness and flush behavior |
| Ghostty | `zmx attach <session> ./zig-out/bin/ykwm` | partial | Runtime loop works; compatibility edge-cases tracked below |
| Ghostty inside tmux | `tmux -> zmx -> ykwm` | partial | Extra nesting can expose write/backpressure and sizing issues |

## App/Shell Compatibility

| Target | Status | Symptom | Expected | Repro |
|---|---|---|---|---|
| `zsh` prompt + ANSI colors | working | n/a | Prompt colors and escapes render correctly | launch `ykwm`, run `zsh` |
| Nerd Font glyphs | partial | Grapheme-aware rendering is now in place; verify width behavior across prompt themes | Glyphs render in pane content without line drift | run `echo '  󰣇 󰆍'` |
| Split/border separators | partial | Shared border ownership can hide or double separators depending on layout | Exactly one internal divider, full-height | open 2-pane vertical stack |
| `Ctrl+C` forwarding | working | n/a | Interrupt goes to focused pane process, not ykwm | run `sleep 100`, press `Ctrl+C` |
| `fish` startup probe | partial | Primary DA response path added; verify warning is gone in real session | No warning on fish startup | run `fish` in pane |

## Protocol / Query Support

| Feature | Status | Notes |
|---|---|---|
| Primary DA query (`CSI c`) response | working | Multiplexer now detects `CSI c` from app output and writes `CSI ?62;c` reply back to that pane PTY |
| OSC 133 passthrough model | partial | Architecture is compatible (ykwm inside zmx), still validating end-to-end shell UX |
| SGR colors/styles from VT cells | working | Implemented in runtime renderer |
| Cursor placement in focused pane | working | Cursor remapped from focused pane VT cursor |
| Diff-based frame flush | working | Runtime now diffs a cached frame and emits only changed cells (no full-screen clear each frame) |

## Active TODOs

1. Add regression test for fish startup warning (or parser unit test for DA request/reply path).
2. Add a reproducible Starship prompt smoke script and capture pass/fail criteria.
3. Finalize shared-border ownership rules for all layouts (vertical/horizontal/grid).
4. Add Unicode/Nerd Font rendering smoke test with a known glyph set.
5. Promote manual smoke checklist below into automated CI checks.

## Runtime Smoke Checklist

Run these after renderer/protocol changes:

1. `zmx attach dev ./zig-out/bin/ykwm`
   Expected: Runtime stays attached; two panes visible with clean borders.
2. In pane 1: `zsh`
   Expected: Prompt lines are stable (no unexpected extra blank line / wrap drift).
3. In pane 1: `echo '  󰣇 󰆍'`
   Expected: Nerd Font glyphs render; no line spillover.
4. In pane 2: `fish`
   Expected: No Primary Device Attribute warning.
5. In pane 1: `sleep 100` then press `Ctrl+C`
   Expected: `sleep` is interrupted; ykwm remains running.
6. Resize terminal and reattach (`ctrl+\\`, then `zmx attach dev ./zig-out/bin/ykwm`)
   Expected: Layout and prompt rendering remain correct post-resize/reattach.

## Update Process

When you find a compatibility issue:

1. Add/modify an entry above with `status`, symptom, and exact repro command.
2. Link the fix PR/commit in notes once implemented.
3. Move status from `broken/partial` to `working` only after manual repro passes.
