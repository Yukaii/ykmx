# Runtime Flow

This document describes one iteration of the runtime loop in `src/main.zig`.

## 1) Loop Setup

- Read terminal size and derive content rect.
- If size/content changed:
  - resize active layout,
  - force redraw,
  - update cached size/content.

## 2) Input Ingestion

- Read stdin in nonblocking mode.
- Forward bytes to mux input handler with current content rect.
- Flush pending input timeouts.

## 3) Tick and Signals

- Drain process signals (`sigwinch`, `sighup`, `sigterm`).
- Run `mux.tick(...)` to process PTY reads, popup updates, redraw intent, detach/shutdown intent.
- Emit plugin lifecycle events when layout/state/tick snapshots change.

## 4) Plugin and Control Integration

- Process pending plugin actions via `runtime_plugin_actions`.
- Poll control pipe for external `ykmx ctl` commands.
- Publish runtime state snapshot for control/status tooling.

## 5) Frame Composition

- Compute layout rects and popup z-order.
- Build popup masks.
- Compose base windows and popups.
- Apply border glyph pass.
- Repaint chrome/title/buttons with popup-aware suppression.
- Build `RuntimeRenderCell` array for all visible rows.
- Build footer rows.

## 6) Frame Output

- Ensure frame cache size.
- Write content diff and footer bars to terminal.
- Copy current frame into cache.
- Position cursor (focused cursor or safe fallback row).

## 7) Exit Conditions

- Detach request: call `zmx` detach path.
- Shutdown request: exit loop and emit plugin shutdown event.

## Debug Hooks

- Optional compose diagnostics are gated by `YKMX_DEBUG_COMPOSE`.
- Panic path includes recent trace events for crash triage.
