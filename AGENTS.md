# AGENTS.md

This file is the operational index for human and AI contributors working on `ykmx`.

## Purpose

- Keep refactors fast while preserving runtime behavior.
- Provide stable wayfinding for the codebase as `src/main.zig` is split into focused modules.
- Capture non-obvious invariants that should not be broken during extraction work.

## Current Priorities

1. Keep runtime behavior stable (popup compositing, input, resize, scrollback).
2. Continue reducing orchestration complexity in `src/main.zig` by extracting cohesive blocks.
3. Keep documentation current so future refactors do not require rediscovery.

## Fast Start

```bash
zig build
zig test src/main.zig
```

If changing runtime compositing/input code, run both commands before handoff.

## Source Map (Runtime-Critical)

- `src/main.zig`: runtime orchestration loop, debug trace/panic hook, top-level frame pipeline wiring.
- `src/multiplexer.zig`: state machine for tabs/windows/popup manager/input routing/scrollback interactions.
- `src/render_compositor.zig`: low-level composition helpers and popup masks.
- `src/runtime_renderer.zig`: border/chrome/content compose passes.
- `src/runtime_pane_rendering.zig`: pane cell/style/row rendering helpers.
- `src/runtime_frame_output.zig`: terminal frame diff writer and footer painting.
- `src/runtime_compose_debug.zig`: optional compose-debug diagnostics and leak sampling.
- `src/runtime_control_pipe.zig`: control pipe lifecycle/state publishing.
- `src/runtime_plugin_actions.zig`: plugin action dispatch bridge into mux.

For broader module inventory, use `docs/architecture.md` and `docs/module-map.md`.

## Invariants to Preserve

- Popup layering order and mask semantics must remain consistent:
  - `popup_overlay` is border-focused overlay data.
  - `popup_opaque_cover` is full-area suppression for underlying chrome/border visibility.
- Resize path must never place cursor outside visible terminal rows.
- Input path must not corrupt state when rapid resize + mouse drag overlap.
- Scrollback commands should target focused surface (popup when focused).
- Sync-scroll is currently disabled; local navigation mode remains supported.

## Refactor Protocol

1. Extract one cohesive block at a time.
2. Wire callsite in `main.zig` with minimal behavior change.
3. Build and run focused tests.
4. Update docs index and affected architecture notes in `docs/`.

Prefer module boundaries that match runtime phases:

- input/tick/update
- render compose
- frame output
- control/plugin integration

## Documentation Contract

When architecture-affecting changes land, update:

- `docs/README.md` (TOC)
- `docs/architecture.md` (high-level design)
- `docs/module-map.md` (module ownership and responsibilities)
- `docs/refactor-log.md` (what moved and why)

This keeps future lookup and extraction work fast.
