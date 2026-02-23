# Refactor Log

This file tracks behavior-preserving extraction steps from `src/main.zig`.

## 2026-02-22

- Extracted runtime frame output logic to `src/runtime_frame_output.zig`.
  - Moved content diff writer and footer painting from `main.zig`.
  - Kept render-footer trace event in `main.zig` to preserve trace semantics.
  - Result: `src/main.zig` reduced below 1k lines.

## Prior extraction milestones (current codebase state)

- Extracted compositor primitives to `src/render_compositor.zig`.
- Extracted runtime rendering passes to `src/runtime_renderer.zig`.
- Extracted pane rendering helpers to `src/runtime_pane_rendering.zig`.
- Extracted compose-debug diagnostics to `src/runtime_compose_debug.zig`.
- Extracted control pipe lifecycle/state to `src/runtime_control_pipe.zig`.
- Extracted plugin action dispatch bridge to `src/runtime_plugin_actions.zig`.
- Extracted runtime CLI path to `src/runtime_cli.zig`.
- Added render/cell support modules (`runtime_render_types`, `runtime_cells`).

## Notes

- Keep one cohesive extraction per change when possible.
- After each extraction, run:
  - `zig build`
  - `zig test src/main.zig`
