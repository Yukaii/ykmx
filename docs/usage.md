# ykwm Usage

## Quick Start

Run the current POC flow:

```bash
zig build run
```

Run tests:

```bash
zig build test
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

## zmx Workflow

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
- `Ctrl+G j` / `Ctrl+G k` next/prev window
- `Ctrl+G Space` cycle layout
- `Ctrl+G p` open popup (`fzf` flow)
- `Ctrl+G Escape` close focused popup
- `Ctrl+G Tab` cycle popup focus
- `Ctrl+G u` / `Ctrl+G d` page up/down scrollback
- `Ctrl+G \` detach request

## Mouse

- Left click focuses a pane.
- Click coordinates are forwarded to the focused pane PTY for terminal apps that support mouse-position actions.

