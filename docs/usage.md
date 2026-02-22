# ykmx Usage

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

Config file lookup (first existing path wins):

- `$XDG_CONFIG_HOME/ykmx/config`
- `$XDG_CONFIG_HOME/ykmx/config.toml`
- `$HOME/.config/ykmx/config`
- `$HOME/.config/ykmx/config.toml`

## CLI

```bash
ykmx --help
ykmx --version
ykmx --benchmark 300
ykmx --smoke-zmx my-session
ykmx ctl help
```

- `--benchmark [N]` runs a lightweight frame timing benchmark and prints avg/p95/max.
- `--smoke-zmx [session]` performs a temporary `zmx attach` round-trip smoke check.
- `ctl` sends control commands to the current running ykmx session via `$YKMX_CONTROL_PIPE`.

Control CLI commands:

```bash
ykmx ctl new-window
ykmx ctl close-window
ykmx ctl open-popup
ykmx ctl open-popup -- lazygit
ykmx ctl open-popup --cwd /path/to/project
ykmx ctl open-panel 8 4 100 24
ykmx ctl open-panel 8 4 100 24 --cwd /path/to/project
ykmx ctl hide-panel 1
ykmx ctl show-panel 1
ykmx ctl status
ykmx ctl list-windows
ykmx ctl list-panels
ykmx ctl command panel.sidebar.toggle
ykmx ctl json '{"v":1,"command":"open_popup"}'
```

Runtime exports these environment variables:

- `YKMX_SESSION_ID`: current ykmx session identifier
- `YKMX_CONTROL_PIPE`: FIFO path for control commands (for `ykmx ctl`)
- `YKMX_STATE_FILE`: text snapshot path used by `ykmx ctl status|list-*`

Both pane shells and plugin processes inherit these env vars, so external scripts and plugins can control the active session.

Compatibility helpers:

- `scripts/compat/ci-smoke.sh` runs CI-friendly compatibility checks.
- `scripts/compat/manual-soak.sh` prints the interactive Ghostty/zmx soak checklist.

## zmx Workflow

Build binary first:

```bash
zig build
```

Run from local binary path (works even if `ykmx` is not on your PATH yet):

```bash
zmx attach dev ./zig-out/bin/ykmx
```

Or, after adding to PATH / installing:

```bash
zmx attach dev ykmx
```

Create or attach to a persistent session running ykmx:

```bash
zmx attach dev ykmx
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
- `Ctrl+G p` toggle popup shell (default core behavior, plugin-overridable)
- `Ctrl+G Escape` close focused popup immediately (plugin-overridable)
- `Ctrl+G Tab` cycle popup focus (plugin-overridable)
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
  - `compositor`: always consume mouse for ykmx interactions

## Plugins (Bun scaffold)

- Enable with `plugins_enabled=true` and `plugin_dir=/abs/path/to/plugins`.
- For multiple plugins, set `plugins_dir=/abs/path/to/plugins.d` and place each plugin at:
  - `<plugins_dir>/<plugin-name>/index.ts`
  - optional `<plugins_dir>/<plugin-name>/plugin.toml` with:
    - `enabled=true|false` (default `true`)
    - `order=<int>` (default `0`, lower loads first)
- To search multiple plugin collections without editing paths, use:
  - `plugins_dirs=["/abs/path/plugins.d","/another/plugins.d"]`
- Per-plugin config sections are supported:
  - `[plugin.<plugin-name>]`
  - keys are delivered to that plugin as `on_plugin_config` events
  - example:
    - `[plugin.sidebar-panel]`
    - `side=right`
    - `width=42`
    - `[plugin.bottom-panel]`
    - `height=8`
- Prefixed panel toggle keys are configurable:
  - `key_toggle_sidebar_panel=ctrl+s`
  - `key_toggle_bottom_panel=ctrl+b`
- Arbitrary plugin command keybindings are configurable:
  - `plugin_keybindings=["ctrl+s:panel.sidebar.toggle","ctrl+b:panel.bottom.toggle"]`
  - Plugin registers command names at runtime with:
    - `{"v":1,"action":"register_command","command":"panel.sidebar.toggle"}`
- Each `plugins_dirs` entry can be either:
  - a plugin root directory containing subfolders (`<dir>/<plugin-name>/index.ts`)
  - or a direct plugin directory containing `index.ts`
- Use either `plugin_dir` or `plugins_dir` for a given plugin path; avoid loading the same plugin from both.
- In this repository, the PaperWM example plugin lives at:
  - `docs/examples/plugins.d/paperwm/index.ts`
- Desktop floating WM example (overlap + free drag/resize + controls) lives at:
  - `docs/examples/plugins.d/desktop-wm/index.ts`
- Standalone popup keybinding/plugin-control example lives at:
  - `docs/examples/plugins.d/popup-controls/index.ts`
  - optional plugin config:
    - `[plugin.popup-controls]`
    - `persistent_process=true` (hide/show popup while keeping PTY alive)
- Sidebar panel example lives at:
  - `docs/examples/plugins.d/sidebar-panel/index.ts`
  - optional plugin config:
    - `[plugin.sidebar-panel]`
    - `persistent_process=true` (hide/show while keeping PTY alive)
- Bottom panel example lives at:
  - `docs/examples/plugins.d/bottom-panel/index.ts`
  - these examples use arbitrary command names (`panel.sidebar.toggle`, `panel.bottom.toggle`)
  - optional plugin config:
    - `[plugin.bottom-panel]`
    - `persistent_process=true` (hide/show while keeping PTY alive)
- Runtime spawns `bun run <plugin_dir>/index.ts` as an out-of-process plugin host.
- Set `layout_backend=plugin` to allow plugin-driven layout rect computation.
- For interactive layout plugins (drag/resize/floating state), also set `plugins_enabled=true` so the same plugin host handles both layout compute and pointer/actions.
- Type definitions for plugin authors: `docs/examples/plugins.d/paperwm/types.ts`.
- Helper utilities for plugin authors: `docs/examples/plugins.d/paperwm/helpers.ts`.
- Current stdin hook protocol is NDJSON events:
  - `{"v":1,"event":"on_start","layout":"..."}`
  - `{"v":1,"event":"on_layout_changed","layout":"..."}`
  - `{"v":1,"event":"on_plugin_config","key":"...","value":"..."}`
  - `{"v":1,"event":"on_state_changed","reason":"...","state":{...}}`
  - `{"v":1,"event":"on_tick","stats":{...},"state":{...}}`
  - `{"v":1,"event":"on_pointer","pointer":{...},"hit":{...}}`
  - `{"v":1,"event":"on_command","command":"<string-command-name>"}`
  - `{"v":1,"event":"on_shutdown"}`
- `state` currently includes layout, window/focus info, tab info, master settings, mouse mode, sync-scroll flag, and current screen rect.
  - `state.panel_count` reflects currently visible panels.
- For plugin layout backend, ykmx also sends:
  - `{"v":1,"id":N,"event":"on_compute_layout","params":{...}}`
  - `params.window_ids` carries stable visible window IDs in layout index order.
- Plugin may write to stdout:
  - `{"v":1,"id":N,"rects":[{"x":0,"y":0,"width":80,"height":24}, ...]}`
  - or `{"v":1,"id":N,"fallback":true}` to use native layout.
- Plugin may also emit action messages (applied by ykmx runtime):
  - `{"v":1,"action":"cycle_layout"}`
  - `{"v":1,"action":"set_layout","layout":"paperwm"}`
  - `{"v":1,"action":"set_master_ratio_permille","value":650}`
  - `{"v":1,"action":"request_redraw"}`
  - `{"v":1,"action":"minimize_focused_window"}`
  - `{"v":1,"action":"restore_all_minimized_windows"}`
  - `{"v":1,"action":"move_focused_window_to_index","index":1}`
  - `{"v":1,"action":"move_window_by_id_to_index","window_id":123,"index":1}`
  - `{"v":1,"action":"close_focused_window"}`
  - `{"v":1,"action":"restore_window_by_id","window_id":123}`
  - `{"v":1,"action":"register_command","command":"<string-command-name>","enabled":true}`
  - `{"v":1,"action":"open_shell_panel"}`
  - `{"v":1,"action":"close_focused_panel"}`
  - `{"v":1,"action":"cycle_panel_focus"}`
  - `{"v":1,"action":"toggle_shell_panel"}`
  - `{"v":1,"action":"open_shell_panel_rect","x":8,"y":4,"width":100,"height":24,"modal":true,"show_border":true,"show_controls":false,"transparent_background":false}`
  - `{"v":1,"action":"close_panel_by_id","panel_id":1}`
  - `{"v":1,"action":"focus_panel_by_id","panel_id":1}`
  - `{"v":1,"action":"move_panel_by_id","panel_id":1,"x":12,"y":6}`
  - `{"v":1,"action":"resize_panel_by_id","panel_id":1,"width":110,"height":26}`
  - `{"v":1,"action":"set_panel_visibility_by_id","panel_id":1,"visible":false}`
  - `{"v":1,"action":"set_panel_style_by_id","panel_id":1,"show_border":true,"show_controls":false,"transparent_background":false}`
  - `{"v":1,"action":"set_ui_bars","toolbar_line":"...","tab_line":"...","status_line":"..."}`
  - `{"v":1,"action":"clear_ui_bars"}`
- Plugin panel actions are ownership-scoped:
  - panels opened by plugin `A` can only be closed/focused/moved/resized/styled by plugin `A`
  - this prevents cross-plugin panel conflicts when multiple panel plugins are active
- Plugin errors/crashes are isolated; ykmx continues running.

Desktop control buttons:

- Pane title bar now draws `[_][+][x]` on the right.
- Minimized windows are listed in a toolbar row above tab/status bars as `min: [id:title] ...`.
- Pointer hit payload reports which button was clicked:
  - `on_minimize_button`
  - `on_maximize_button`
  - `on_close_button`
  - `on_restore_button` (for minimized-toolbar restore targets)
