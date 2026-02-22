# ykwm Usage

## Quick Start

Run the current POC flow:

```bash
zig build run
```

Run tests:

```bash
zig build test
scripts/compat/ci-smoke.sh
```

## CLI

```bash
ykwm --help
ykwm --version
ykwm --benchmark 300
ykwm --smoke-zmx my-session
```

- `--benchmark [N]` runs a lightweight frame timing benchmark and prints avg/p95/max.
- `--smoke-zmx [session]` performs a temporary `zmx attach` round-trip smoke check.

Compatibility helpers:

- `scripts/compat/ci-smoke.sh` runs CI-friendly compatibility checks.
- `scripts/compat/manual-soak.sh` prints the interactive Ghostty/zmx soak checklist.

## zmx Workflow

Build binary first:

```bash
zig build
```

Run from local binary path (works even if `ykwm` is not on your PATH yet):

```bash
zmx attach dev ./zig-out/bin/ykwm
```

Or, after adding to PATH / installing:

```bash
zmx attach dev ykwm
```

Create or attach to a persistent session running ykwm:

```bash
zmx attach dev ykwm
```

Detach from current zmx client:

```text
Ctrl+\
```

Reattach later:

```bash
zmx attach dev
```

## Keybindings (Current)

Prefix is `Ctrl+G`.

- `Ctrl+G c` create window
- `Ctrl+G x` close focused window
- `Ctrl+G t` new tab
- `Ctrl+G w` close active tab
- `Ctrl+G ]` / `Ctrl+G [` next/prev tab
- `Ctrl+G m` move focused window to next tab
- `Ctrl+G h` / `Ctrl+G j` / `Ctrl+G k` / `Ctrl+G l` focus left/down/up/right pane
- `Ctrl+G J` / `Ctrl+G K` next/prev window (index order)
- `Ctrl+G Space` cycle layout
- `Ctrl+G H` / `Ctrl+G L` shrink/grow master area ratio
- `Ctrl+G I` / `Ctrl+G O` increase/decrease master pane count
- `Ctrl+G p` toggle popup shell (floating terminal window)
- `Ctrl+G Escape` close focused popup immediately
- `Ctrl+G Tab` cycle popup focus
- `Ctrl+G u` / `Ctrl+G d` page up/down scrollback
- `Ctrl+G s` toggle synchronized scroll across visible panes in active tab
- `Ctrl+G M` cycle mouse mode (`hybrid` -> `passthrough` -> `compositor`)
- `Ctrl+G \` detach request

Current layout cycle order: `vertical_stack -> horizontal_stack -> grid -> paperwm -> fullscreen`.

Scrollback navigation mode (while scrolled up):

- `k` scroll up by 1 line
- `j` scroll down by 1 line
- `h` / `l` move selection cursor left/right
- `0` move selection cursor to line start
- `$` move selection cursor to line end
- `Ctrl+u` page up
- `Ctrl+d` page down
- `g` jump to top of scrollback
- `G` jump to bottom (live view)
- `/` start search query, then press Enter
- `n` repeat last search direction
- `N` repeat last search in opposite direction
- `q` or `Esc` exit scrollback view (jump to bottom)
- non-prefixed input is consumed (not sent to app PTY) until you return to bottom

When sync scroll is enabled, navigation controls are accepted immediately (even at `scroll=+0`).

## Mouse

- Default mode is `hybrid`.
  - first click in a non-focused pane: switch focus only
  - click in already-focused pane content: forwarded to app PTY (for fish click-to-move and similar)
  - motion / non-left events: forwarded only if that pane enabled mouse reporting (`CSI ?1000/1002/1003/1006 h`)
  - pane borders/dividers: handled by compositor (focus + drag resize)
- `Ctrl+G M` cycles modes:
  - `hybrid`: coordinate-based split behavior
  - `passthrough`: always forward mouse to app
  - `compositor`: always consume mouse for ykwm interactions

## Plugins (Bun scaffold)

- Enable with `plugins_enabled=true` and `plugin_dir=/abs/path/to/plugins`.
- For multiple plugins, set `plugins_dir=/abs/path/to/plugins.d` and place each plugin at:
  - `<plugins_dir>/<plugin-name>/index.ts`
- In this repository, the PaperWM example plugin lives at:
  - `docs/examples/plugins.d/paperwm/index.ts`
- Desktop floating WM example (overlap + free drag/resize + controls) lives at:
  - `docs/examples/plugins.d/desktop-wm/index.ts`
- Runtime spawns `bun run <plugin_dir>/index.ts` as an out-of-process plugin host.
- Set `layout_backend=plugin` to allow plugin-driven layout rect computation.
- For interactive layout plugins (drag/resize/floating state), also set `plugins_enabled=true` so the same plugin host handles both layout compute and pointer/actions.
- Type definitions for plugin authors: `docs/examples/plugins.d/paperwm/types.ts`.
- Helper utilities for plugin authors: `docs/examples/plugins.d/paperwm/helpers.ts`.
- Current stdin hook protocol is NDJSON events:
  - `{"v":1,"event":"on_start","layout":"..."}`
  - `{"v":1,"event":"on_layout_changed","layout":"..."}`
  - `{"v":1,"event":"on_state_changed","reason":"...","state":{...}}`
  - `{"v":1,"event":"on_tick","stats":{...},"state":{...}}`
  - `{"v":1,"event":"on_pointer","pointer":{...},"hit":{...}}`
  - `{"v":1,"event":"on_shutdown"}`
- `state` currently includes layout, window/focus info, tab info, master settings, mouse mode, sync-scroll flag, and current screen rect.
- For plugin layout backend, ykwm also sends:
  - `{"v":1,"id":N,"event":"on_compute_layout","params":{...}}`
  - `params.window_ids` carries stable visible window IDs in layout index order.
- Plugin may write to stdout:
  - `{"v":1,"id":N,"rects":[{"x":0,"y":0,"width":80,"height":24}, ...]}`
  - or `{"v":1,"id":N,"fallback":true}` to use native layout.
- Plugin may also emit action messages (applied by ykwm runtime):
  - `{"v":1,"action":"cycle_layout"}`
  - `{"v":1,"action":"set_layout","layout":"paperwm"}`
  - `{"v":1,"action":"set_master_ratio_permille","value":650}`
  - `{"v":1,"action":"request_redraw"}`
  - `{"v":1,"action":"minimize_focused_window"}`
  - `{"v":1,"action":"restore_all_minimized_windows"}`
  - `{"v":1,"action":"move_focused_window_to_index","index":1}`
  - `{"v":1,"action":"close_focused_window"}`
  - `{"v":1,"action":"restore_window_by_id","window_id":123}`
  - `{"v":1,"action":"set_ui_bars","toolbar_line":"...","tab_line":"...","status_line":"..."}`
  - `{"v":1,"action":"clear_ui_bars"}`
- Plugin errors/crashes are isolated; ykwm continues running.

Desktop control buttons:

- Pane title bar now draws `[_][+][x]` on the right.
- Minimized windows are listed in a toolbar row above tab/status bars as `min: [id:title] ...`.
- Pointer hit payload reports which button was clicked:
  - `on_minimize_button`
  - `on_maximize_button`
  - `on_close_button`
  - `on_restore_button` (for minimized-toolbar restore targets)
