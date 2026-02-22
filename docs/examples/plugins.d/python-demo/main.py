#!/usr/bin/env python3
import json
import sys

OPEN_CMD = "python.demo.open"
opening_panel = False


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


for raw in sys.stdin:
    raw = raw.strip()
    if not raw:
        continue
    try:
        ev = json.loads(raw)
    except Exception:
        continue

    kind = ev.get("event")

    if kind == "on_start":
        emit({"v": 1, "action": "register_command", "command": OPEN_CMD})
        emit({
            "v": 1,
            "action": "set_ui_bars",
            "toolbar_line": " python-demo | command: python.demo.open ",
            "tab_line": " python plugin runtime active ",
            "status_line": " press bound key for python.demo.open ",
        })
        emit({
            "v": 1,
            "action": "set_chrome_style",
            "active_title_sgr": "1;30;47",
            "inactive_title_sgr": "30;47",
            "active_border_sgr": "30;47",
            "inactive_border_sgr": "30;47",
            "active_buttons_sgr": "1;34;47",
            "inactive_buttons_sgr": "34;47",
        })
        continue

    if kind == "on_command" and ev.get("command") == OPEN_CMD:
        emit({
            "v": 1,
            "action": "open_shell_panel_rect",
            "x": 10,
            "y": 3,
            "width": 90,
            "height": 24,
            "modal": False,
            "show_border": True,
            "show_controls": True,
            "transparent_background": False,
        })
        opening_panel = True
        continue

    if kind == "on_state_changed" and opening_panel:
        state = ev.get("state", {})
        if state.get("has_focused_panel"):
            panel_id = state.get("focused_panel_id")
            emit({
                "v": 1,
                "action": "set_panel_chrome_style_by_id",
                "panel_id": panel_id,
                "active_title_sgr": "1;37;45",
                "inactive_title_sgr": "37;45",
                "active_border_sgr": "37;45",
                "inactive_border_sgr": "37;45",
                "active_buttons_sgr": "1;33;45",
                "inactive_buttons_sgr": "33;45",
            })
            opening_panel = False
        continue

    if kind == "on_shutdown":
        emit({"v": 1, "action": "clear_ui_bars"})
        break
