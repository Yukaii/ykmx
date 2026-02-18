#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

cat <<'EOF'
Manual runtime compatibility soak (Ghostty + zmx):

1) Build:
   zig build

2) Launch:
   zmx attach dev ./zig-out/bin/ykwm

3) In ykwm panes, run:
   fish
   zoxide query .
   printf 'one\ntwo\nthree\n' | fzf --height=100% --layout=reverse
   echo '  󰣇 󰆍'

4) Validate:
   - no fish startup warning about terminal probe/device attributes
   - fzf redraw remains stable (no raw CSI text artifacts)
   - zoxide + prompt flows do not corrupt pane rendering
   - Nerd Font glyph line has no wrap drift
EOF
