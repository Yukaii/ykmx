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
- `Ctrl+G M` cycle mouse mode (`hybrid` -> `passthrough` -> `compositor`)
- `Ctrl+G \` detach request

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
