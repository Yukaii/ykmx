import { isCommandEvent, isStateChangedEvent, readEvents, writeAction } from "./helpers";

const ENABLE_PANEL_RESIZE = false;
const ENABLE_PANEL_DRAG = false;
const ENABLE_PANEL_CONTROLS = false;
const ENABLE_PANEL_TRANSPARENT_BG = false;

let popupPanelId: number | null = null;
let opening = false;

async function main() {
  for await (const ev of readEvents()) {
    if (ev.event === "on_start") {
      await writeAction({ v: 1, action: "register_command", command: "open_popup" });
      await writeAction({ v: 1, action: "register_command", command: "close_popup" });
      await writeAction({ v: 1, action: "register_command", command: "cycle_popup" });
      continue;
    }

    if (isStateChangedEvent(ev)) {
      if (opening && ev.state.has_focused_panel) {
        popupPanelId = ev.state.focused_panel_id;
        opening = false;
      }
      if (ev.state.panel_count === 0) {
        popupPanelId = null;
        opening = false;
      }
      continue;
    }

    if (!isCommandEvent(ev)) continue;

    if (ev.command === "open_popup") {
      if (popupPanelId) {
        await writeAction({ v: 1, action: "close_panel_by_id", panel_id: popupPanelId });
        popupPanelId = null;
        opening = false;
      } else {
        opening = true;
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
      if (popupPanelId) {
        await writeAction({ v: 1, action: "close_panel_by_id", panel_id: popupPanelId });
        popupPanelId = null;
        opening = false;
      }
      continue;
    }
    if (ev.command === "cycle_popup") {
      if (popupPanelId) {
        await writeAction({ v: 1, action: "focus_panel_by_id", panel_id: popupPanelId });
      }
    }

    // Reserved capability toggles for panel-like popup behavior.
    // Keep disabled by default to match legacy popup UX.
    void ENABLE_PANEL_RESIZE;
    void ENABLE_PANEL_DRAG;
  }
}

main().catch(() => {});
