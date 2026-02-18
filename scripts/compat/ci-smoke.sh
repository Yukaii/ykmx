#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

echo "[compat] running unit tests"
zig build test

echo "[compat] building binary"
zig build

echo "[compat] checking CLI probes"
./zig-out/bin/ykwm --version >/dev/null
./zig-out/bin/ykwm --benchmark 20 >/dev/null
./zig-out/bin/ykwm --benchmark-layout 50 >/dev/null

echo "[compat] checking unicode fixture bytes"
glyphs='  󰣇 󰆍'
bytes="$(printf '%s' "$glyphs" | wc -c | tr -d '[:space:]')"
if [[ "${bytes}" -lt 10 ]]; then
  echo "[compat] glyph fixture unexpectedly short"
  exit 1
fi

echo "[compat] checking optional shell tools"
if command -v fish >/dev/null 2>&1; then
  fish --version >/dev/null
fi
if command -v zoxide >/dev/null 2>&1; then
  zoxide --version >/dev/null
fi
if command -v fzf >/dev/null 2>&1; then
  fzf --version >/dev/null
fi
if command -v starship >/dev/null 2>&1; then
  TERM=xterm-256color STARSHIP_CONFIG=/dev/null starship prompt --status=0 --jobs=0 --cmd-duration=0 --keymap=insert >/dev/null 2>&1
fi

echo "[compat] smoke checks passed"
