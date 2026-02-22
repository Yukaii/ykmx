import { isCommandEvent, isPluginConfigEvent, isStateChangedEvent, readEvents, writeAction } from "./helpers";

const ENABLE_PANEL_RESIZE = false;
const ENABLE_PANEL_DRAG = false;
const ENABLE_PANEL_CONTROLS = false;
const ENABLE_PANEL_TRANSPARENT_BG = false;

let popupPanelId: number | null = null;
let opening = false;
let visible = false;
let persistentProcess = true;
let popupX = 24;
let popupY = 6;
let popupWidth = 110;
let popupHeight = 26;

function parseBoolLike(value: string): boolean {
  const s = value.trim().toLowerCase();
  return s === "1" || s === "true" || s === "yes" || s === "on";
}

function parseIntLike(value: string): number | null {
  const n = Number.parseInt(value.trim(), 10);
  return Number.isFinite(n) ? n : null;
}

async function main() {
  for await (const ev of readEvents()) {
    if (isPluginConfigEvent(ev)) {
      if (ev.key === "persistent_process") {
        persistentProcess = parseBoolLike(ev.value);
      } else if (ev.key === "popup_x") {
        const n = parseIntLike(ev.value);
        if (n !== null) popupX = n;
      } else if (ev.key === "popup_y") {
        const n = parseIntLike(ev.value);
        if (n !== null) popupY = n;
      } else if (ev.key === "popup_width") {
        const n = parseIntLike(ev.value);
        if (n !== null) popupWidth = n;
      } else if (ev.key === "popup_height") {
        const n = parseIntLike(ev.value);
        if (n !== null) popupHeight = n;
      }
      continue;
    }

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
        visible = true;
      }
      continue;
    }

    if (!isCommandEvent(ev)) continue;

    if (ev.command === "open_popup") {
      if (popupPanelId) {
        if (persistentProcess) {
          const nextVisible = !visible;
          await writeAction({ v: 1, action: "set_panel_visibility_by_id", panel_id: popupPanelId, visible: nextVisible });
          if (nextVisible) {
            await writeAction({ v: 1, action: "focus_panel_by_id", panel_id: popupPanelId });
          }
          visible = nextVisible;
        } else {
          await writeAction({ v: 1, action: "close_panel_by_id", panel_id: popupPanelId });
          popupPanelId = null;
          opening = false;
          visible = false;
        }
      } else {
        opening = true;
        visible = true;
        await writeAction({
          v: 1,
          action: "open_shell_panel_rect",
          x: popupX,
          y: popupY,
          width: popupWidth,
          height: popupHeight,
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
        if (persistentProcess) {
          await writeAction({ v: 1, action: "set_panel_visibility_by_id", panel_id: popupPanelId, visible: false });
          visible = false;
        } else {
          await writeAction({ v: 1, action: "close_panel_by_id", panel_id: popupPanelId });
          popupPanelId = null;
          opening = false;
          visible = false;
        }
      }
      continue;
    }
    if (ev.command === "cycle_popup") {
      if (popupPanelId && visible) {
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
