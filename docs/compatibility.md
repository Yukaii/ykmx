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
| Nerd Font glyphs | partial | Some glyphs were skipped in earlier builds; unicode path recently updated | Glyphs render in pane content | run `echo '  󰣇 󰆍'` |
| Split/border separators | partial | Shared border ownership can hide or double separators depending on layout | Exactly one internal divider, full-height | open 2-pane vertical stack |
| `Ctrl+C` forwarding | working | n/a | Interrupt goes to focused pane process, not ykwm | run `sleep 100`, press `Ctrl+C` |
| `fish` startup probe | broken | fish warns about missing Primary Device Attribute response | No warning on fish startup | run `fish` in pane |

## Protocol / Query Support

| Feature | Status | Notes |
|---|---|---|
| Primary DA query (`CSI c`) response | broken | Needed for fish terminal-compatibility checks |
| OSC 133 passthrough model | partial | Architecture is compatible (ykwm inside zmx), still validating end-to-end shell UX |
| SGR colors/styles from VT cells | working | Implemented in runtime renderer |
| Cursor placement in focused pane | working | Cursor remapped from focused pane VT cursor |

## Active TODOs

1. Implement Primary DA reply handling for pane PTYs (`CSI c` -> `CSI ?62;c` or chosen profile).
2. Add regression test for fish startup warning (or parser unit test for DA request/reply path).
3. Finalize shared-border ownership rules for all layouts (vertical/horizontal/grid).
4. Add Unicode/Nerd Font rendering smoke test with a known glyph set.
5. Add a compatibility CI smoke command section once runtime harness supports scripted checks.

## Update Process

When you find a compatibility issue:

1. Add/modify an entry above with `status`, symptom, and exact repro command.
2. Link the fix PR/commit in notes once implemented.
3. Move status from `broken/partial` to `working` only after manual repro passes.

