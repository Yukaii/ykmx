# Module Map

This file maps module ownership and responsibilities for fast navigation.

## Runtime Orchestration

- `src/main.zig`
  - CLI dispatch (`--help`, `--version`, `--benchmark`, `ctl`, runtime mode).
  - Runtime loop sequencing (input/tick/render/output/control/plugin).
  - Panic trace ring buffer and top-level trace events.

## Multiplexer Core

- `src/multiplexer.zig`
  - Window/tab lifecycle and focus state.
  - Popup manager ownership and popup focus behavior.
  - Input handling and keybinding dispatch.
  - Scrollback state and navigation mode toggles.

## Rendering

- `src/render_compositor.zig`
  - Mask and overlay primitives.
  - Rect clearing and draw helpers.
  - Popup order collection helpers.
  - Frame row math helpers.

- `src/runtime_renderer.zig`
  - Base window composition.
  - Popup composition and z-order interactions.
  - Border/chrome/title/buttons passes.
  - Content-to-cell composition.

- `src/runtime_pane_rendering.zig`
  - Pane cell lookup and style serialization.
  - Styled row and plain line helpers.

- `src/runtime_frame_output.zig`
  - Footer row composition.
  - Content diff writing and footer painting to terminal.

- `src/runtime_render_types.zig`
  - Render-time cell/cache/pane reference structs.

- `src/runtime_cells.zig`
  - Cell equality/safety helpers.
  - Background tag/opacity helpers.

- `src/runtime_compose_debug.zig`
  - Compose-debug logging for popup summaries and background leak sampling.

## Terminal and VT

- `src/runtime_terminal.zig`
  - Raw terminal mode lifecycle.
  - Terminal size and content rect calculations.
  - Nonblocking stdin reads.

- `src/runtime_vt.zig`
  - VT state cache lifecycle and sync helpers.
  - Warm/prune behavior for window VT instances.

## Control and Plugin Integration

- `src/runtime_control_pipe.zig`
  - Control FIFO setup, polling, and env export.
  - Runtime state snapshot writes.

- `src/runtime_control.zig`
  - Command JSON decoding and mux command application.

- `src/runtime_plugin_actions.zig`
  - Action bridge from plugin protocol to mux operations.

- `src/runtime_plugin_state.zig`
  - Runtime state projection for plugin lifecycle events.

- `src/plugin_manager.zig`, `src/plugin_host.zig`
  - Plugin process orchestration and protocol transport.

## Layout and Workspace

- `src/workspace.zig`
  - Tab/workspace ownership and active-tab behavior.

- `src/layout.zig`, `src/layout_native.zig`, `src/layout_opentui.zig`, `src/runtime_layout.zig`
  - Layout APIs, native algorithms, optional backend selection.

## User-Facing Support

- `src/runtime_cli.zig`
  - `ykmx ctl` command parsing and output.

- `src/runtime_footer.zig`
  - Footer/status/tab/minimized toolbar text and hit-testing helpers.

- `src/status.zig`, `src/benchmark.zig`
  - Status/footer and benchmark output paths.
