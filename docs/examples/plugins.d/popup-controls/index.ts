import { isCommandEvent, isStateChangedEvent, readEvents, writeAction } from "./helpers";

const ENABLE_PANEL_RESIZE = false;
const ENABLE_PANEL_DRAG = false;
const ENABLE_PANEL_CONTROLS = false;
const ENABLE_PANEL_TRANSPARENT_BG = false;

let panelCount = 0;

async function main() {
  for await (const ev of readEvents()) {
    if (ev.event === "on_start") {
      await writeAction({ v: 1, action: "register_command", command: "open_popup" });
      await writeAction({ v: 1, action: "register_command", command: "close_popup" });
      await writeAction({ v: 1, action: "register_command", command: "cycle_popup" });
      continue;
    }

    if (isStateChangedEvent(ev)) {
      panelCount = ev.state.panel_count;
      continue;
    }

    if (!isCommandEvent(ev)) continue;

    if (ev.command === "open_popup") {
      if (panelCount > 0) {
        await writeAction({ v: 1, action: "close_focused_panel" });
      } else {
        await writeAction({
          v: 1,
          action: "open_shell_panel_rect",
          x: 24,
          y: 6,
          width: 110,
          height: 26,
          modal: true,
          show_border: true,
          show_controls: ENABLE_PANEL_CONTROLS,
          transparent_background: ENABLE_PANEL_TRANSPARENT_BG,
        });
      }
      continue;
    }
    if (ev.command === "close_popup") {
      await writeAction({ v: 1, action: "close_focused_panel" });
      continue;
    }
    if (ev.command === "cycle_popup") {
      await writeAction({ v: 1, action: "cycle_panel_focus" });
    }

    // Reserved capability toggles for panel-like popup behavior.
    // Keep disabled by default to match legacy popup UX.
    void ENABLE_PANEL_RESIZE;
    void ENABLE_PANEL_DRAG;
  }
}

main().catch(() => {});
