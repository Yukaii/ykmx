# ykmx

Experimental terminal multiplexer in Zig, designed for modern terminal workflows (Ghostty + `zmx`) with tiling layouts, tabs, popups, mouse interactions, and plugin-extensible behavior.

[![asciicast](https://asciinema.org/a/792060.svg)](https://asciinema.org/a/792060)

## Current Status

- Active prototype (`0.1.0-dev`)
- Runtime loop works as the default mode
- Built-in compatibility checks and manual soak scripts are included

## Features

- Multiple layouts: `vertical_stack`, `horizontal_stack`, `grid`, `paperwm`, `fullscreen`
- Tabs/workspaces with window movement between tabs
- Popup shell and panel controls
- Scrollback mode with search/navigation
- Mouse modes: `hybrid`, `passthrough`, `compositor`
- Optional plugin host (Bun-based process model)
- Optional plugin layout backend (`layout_backend=plugin`)

## Requirements

- Zig `0.15.2` or newer (project minimum)
- A POSIX-like environment (macOS/Linux)
- Optional:
  - `zmx` for session attach/detach workflow
  - `bun` for TypeScript plugin examples
  - Ghostty for the compatibility path documented in this repo

## Build and Run

```bash
# Build
zig build

# Run interactive runtime loop
zig build run

# Run tests
zig build test

# Run compatibility smoke checks
zig build compat
# or directly:
scripts/compat/ci-smoke.sh
```

Binary output:

- `./zig-out/bin/ykmx`

## CLI

```bash
ykmx --help
ykmx --version
ykmx --benchmark 300
ykmx --benchmark-layout 500
ykmx --smoke-zmx my-session
```

## Quick zmx Workflow

```bash
# Build first
zig build

# Start or attach to a session running ykmx
zmx attach dev ./zig-out/bin/ykmx

# Reattach later
zmx attach dev
```

Detach from the current `zmx` client with `Ctrl+\`.

## Configuration

Config is loaded from the first existing file:

- `$XDG_CONFIG_HOME/ykmx/config`
- `$XDG_CONFIG_HOME/ykmx/config.toml`
- `$XDG_CONFIG_HOME/ykmx/config.zig`
- `$HOME/.config/ykmx/config`
- `$HOME/.config/ykmx/config.toml`
- `$HOME/.config/ykmx/config.zig`

Minimal example:

```toml
layout_backend="native"
default_layout="vertical_stack"
master_count=1
master_ratio_permille=600
gap=1

show_tab_bar=true
show_status_bar=true
mouse_mode="hybrid"

plugins_enabled=false
plugin_dir="$HOME/.config/ykmx/plugins"
plugins_dir="$HOME/.config/ykmx/plugins.d"
```

Reference config lives at `docs/examples/config.toml`.

## Default Keybindings

Prefix key is `Ctrl+G`.

- Windows: `c` create, `x` close, `h/j/k/l` focus direction, `J/K` next/prev by index
- Tabs: `t` new, `w` close active, `]`/`[` next/prev, `m` move focused window to next tab
- Layout: `Space` cycle layout, `H/L` shrink/grow master ratio, `I/O` master count up/down
- Popup/panels: `p` toggle popup shell, `Esc` close focused popup, `Tab` cycle popup focus
- Scrollback: `u/d` page up/down, `s` toggle synchronized scroll
- Mouse mode: `M` cycle `hybrid -> passthrough -> compositor`
- Detach request: `\`

## Plugins

When `plugins_enabled=true`, ykmx can run plugins as separate processes via:

- `bun run <plugin_dir>/index.ts`

Supported plugin directory modes:

- `plugin_dir=/abs/path/to/plugin` (single plugin)
- `plugins_dir=/abs/path/to/plugins.d` (directory of plugin subfolders)
- `plugins_dirs=[...]` (multiple roots)

Example plugins are in `docs/examples/plugins.d/`:

- `paperwm` (layout example)
- `desktop-wm` (floating overlap + drag/resize + controls)
- `popup-controls`
- `sidebar-panel`
- `bottom-panel`

## Project Docs

- Usage guide: `docs/usage.md`
- Compatibility matrix and checklist: `docs/compatibility.md`
- Implementation plan/context: `docs/plan.md`

## Development Notes

- This is an experimental codebase; interfaces and config keys may change.
- For plugin behavior and NDJSON event/action protocol details, use `docs/usage.md` as the source of truth.
