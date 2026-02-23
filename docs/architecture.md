# Architecture

`ykmx` is a terminal multiplexer runtime built around a single render loop that:

1. reads terminal/input state,
2. updates multiplexer state,
3. composes frame data,
4. writes terminal diffs,
5. publishes control/plugin state.

It is designed to run inside a `zmx`-managed session while preserving modern terminal behavior.

## Runtime Model

- **Entrypoint**: `src/main.zig` parses CLI and hosts `runRuntimeLoop`.
- **Core state machine**: `src/multiplexer.zig` manages tabs, windows, popup manager, input routing, and scrollback behavior.
- **Rendering stack**:
  - `src/render_compositor.zig`: geometry/mask primitives and low-level compositing helpers.
  - `src/runtime_renderer.zig`: base windows, popup composition, border/chrome repaint, content cell assembly.
  - `src/runtime_frame_output.zig`: terminal diff writer and footer painting.
- **Terminal/VT integration**:
  - `src/runtime_terminal.zig`: terminal size, mode enter/leave, nonblocking stdin reads.
  - `src/runtime_vt.zig`: VT state lifecycle, prune/warm behavior.
- **Plugin/control bridge**:
  - `src/runtime_plugin_actions.zig`: plugin action dispatch into mux.
  - `src/runtime_control_pipe.zig`: control FIFO and state snapshot publishing.

## Render Pipeline (Current)

Within `renderRuntimeFrame` in `src/main.zig`:

1. Allocate frame-time buffers (`canvas`, mask arrays, ownership/chrome metadata).
2. Compute active layout rects and collect visible popups in z-order.
3. Precompute popup masks (`popup_overlay`, `popup_cover`, `popup_opaque_cover`).
4. Compose base windows, then compose popups.
5. Apply border glyphs.
6. Repaint chrome/title/buttons with popup-aware suppression.
7. Compose content cells into `RuntimeRenderCell` array.
8. Optionally emit compose-debug diagnostics.
9. Compose footer rows.
10. Write diff to terminal and update frame cache.

## Control and Plugin Data Flow

- Control commands come through `YKMX_CONTROL_PIPE` and are applied to mux state.
- A compact runtime state file is written for `ykmx ctl status|list-*`.
- Plugin manager consumes mux/IO events and emits actions.
- Plugin actions are translated into mux mutations; redraw requests are traced.

## Critical Behavioral Invariants

- `popup_overlay` is border-centric mask metadata; do not use it as full-surface cover.
- `popup_opaque_cover` must suppress underlying chrome/border visibility for opaque popup bodies.
- Cursor fallback row must remain within visible terminal rows for all resize extremes.
- Input handling under rapid resize + mouse drag must not corrupt focus/layout state.
- Scrollback operations must target focused surface (popup when popup is focused).
- Sync-scroll is currently disabled; local scroll navigation mode remains supported.

## Short-Term Refactor Direction

- Keep `main.zig` orchestration-focused and move implementation blocks to phase-specific modules.
- Continue extracting single cohesive units per change.
- For architecture-affecting changes, update `docs/module-map.md` and `docs/refactor-log.md`.
