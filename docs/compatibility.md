# ykmx Compatibility Matrix

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
| Ghostty | direct `ykmx` | working | Core panes + popups + mouse interactions are stable in current runtime |
| Ghostty | `zmx attach <session> ./zig-out/bin/ykmx` | working | Runtime loop, reattach, resize, and pane lifecycle behaviors validated |
| Ghostty inside tmux | `tmux -> zmx -> ykmx` | partial | Nested session can still expose terminal-mediation quirks depending on tmux config |

## App/Shell Compatibility

| Target | Status | Symptom | Expected | Repro |
|---|---|---|---|---|
| `zsh` prompt + ANSI colors | working | n/a | Prompt colors and escapes render correctly | launch `ykmx`, run `zsh` |
| Nerd Font glyphs | partial | Grapheme-aware rendering is now in place; verify width behavior across prompt themes | Glyphs render in pane content without line drift | run `echo '  󰣇 󰆍'` |
| Split/border separators | working | n/a | Exactly one internal divider, full-height | open 2-pane vertical stack, cycle layouts |
| `Ctrl+C` forwarding | working | n/a | Interrupt goes to focused pane process, not ykmx | run `sleep 100`, press `Ctrl+C` |
| `fish` startup probe | partial | Primary DA response path added; verify warning is gone in real session | No warning on fish startup | run `fish` in pane |
| Popup overlay/z-order/focus | working | n/a | Popup overlays panes, focus raise works, toggle/close stable | `Ctrl+G p`, `Ctrl+G Tab`, `Ctrl+G Esc`, `Ctrl+G p` |
| Child exit isolation | working | n/a | Exiting pane/popup process closes only that pane/popup | in popup shell run `exit`, in pane run `exit` |
| Focus redraw/cursor sync | working | n/a | Cursor/focus updates immediately on focus switch | `Ctrl+G h/j/k/l` and `Ctrl+G J/K` |
| Mouse click/drag compositor handling | working | n/a | Click focus + drag resize work; mouse CSI is not injected into pane PTY | click pane, drag divider, verify no `^[[<...` in shell |
| Tab creation interaction | working | n/a | New tab is immediately interactive (auto shell) | `Ctrl+G t` |

## Protocol / Query Support

| Feature | Status | Notes |
|---|---|---|
| Primary DA query (`CSI c`) response | working | Multiplexer now detects `CSI c` from app output and writes `CSI ?62;c` reply back to that pane PTY |
| OSC 133 passthrough model | partial | Architecture is compatible (ykmx inside zmx), still validating end-to-end shell UX |
| SGR colors/styles from VT cells | working | Implemented in runtime renderer |
| Cursor placement in focused pane | working | Cursor remapped from focused pane VT cursor |
| Diff-based frame flush | working | Runtime now diffs a cached frame and emits only changed cells (no full-screen clear each frame) |

## Active TODOs

1. Run full interactive soak for `fish` / `fzf` / `zoxide` after major renderer/protocol changes.
2. Keep the Nerd Font rendering check in Ghostty manual validation loop (font-dependent behavior).
3. Expand CI smoke coverage to include optional installed tool assertions in a controlled environment image.

## Automated Checks

- CI smoke script: `scripts/compat/ci-smoke.sh`
  - runs `zig build test`
  - verifies core CLI probes (`--version`, `--benchmark`, `--benchmark-layout`)
  - validates Unicode/Nerd Font fixture byte path
  - probes optional tools (`fish`, `fzf`, `zoxide`, `starship`) when installed
- GitHub Actions workflow: `.github/workflows/compatibility.yml`
- Manual soak helper: `scripts/compat/manual-soak.sh`

## Runtime Smoke Checklist

Run these after renderer/protocol changes:

1. `zmx attach dev ./zig-out/bin/ykmx`
   Expected: Runtime stays attached; two panes visible with clean borders.
2. In pane 1: `zsh`
   Expected: Prompt lines are stable (no unexpected extra blank line / wrap drift).
3. In pane 1: `echo '  󰣇 󰆍'`
   Expected: Nerd Font glyphs render; no line spillover.
4. In pane 2: `fish`
   Expected: No Primary Device Attribute warning.
5. In pane 1: `sleep 100` then press `Ctrl+C`
   Expected: `sleep` is interrupted; ykmx remains running.
6. Resize terminal and reattach (`ctrl+\\`, then `zmx attach dev ./zig-out/bin/ykmx`)
   Expected: Layout and prompt rendering remain correct post-resize/reattach.
7. Popup overlay/focus/toggle: `Ctrl+G p`, then `Ctrl+G Tab`, then `Ctrl+G Esc`, then `Ctrl+G p`
   Expected: Popup overlays panes correctly, focus cycles, close/toggle are responsive.
8. Process isolation: in popup shell run `exit`; in a normal pane run `exit`
   Expected: Only the exited pane/popup closes; ykmx keeps running.
9. Focus/cursor sync: switch panes via key (`Ctrl+G h/j/k/l` or `Ctrl+G J/K`) and mouse click
   Expected: Cursor jumps immediately to newly focused pane.
10. Mouse drag resize: click divider and drag across columns
    Expected: live resize updates, no runtime crash, and no raw mouse CSI text (`^[[<...`) appears in pane output.
11. Tabs: `Ctrl+G t`, then type in the new tab shell
    Expected: New tab is immediately interactive; no freeze.

## Update Process

When you find a compatibility issue:

1. Add/modify an entry above with `status`, symptom, and exact repro command.
2. Link the fix PR/commit in notes once implemented.
3. Move status from `broken/partial` to `working` only after manual repro passes.
