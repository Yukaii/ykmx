import { isCommandEvent, isPluginConfigEvent, isStateChangedEvent, readEvents, writeAction } from "./helpers";
import type { RuntimeState } from "./types";

const DEFAULT_SIDE: "left" | "right" = "left";
const DEFAULT_WIDTH = 36;

let side: "left" | "right" = DEFAULT_SIDE;
let panelWidth = DEFAULT_WIDTH;
const TOGGLE_COMMAND = "panel.sidebar.toggle";
let persistentProcess = true;

let panelId: number | null = null;
let opening = false;
let visible = false;
let lastState: RuntimeState | null = null;

function parseBoolLike(value: string): boolean {
  const s = value.trim().toLowerCase();
  return s === "1" || s === "true" || s === "yes" || s === "on";
}

function panelRect(state: RuntimeState): { x: number; y: number; width: number; height: number } {
  const width = Math.max(12, Math.min(panelWidth, state.screen.width));
  const x = side === "left" ? state.screen.x : state.screen.x + Math.max(0, state.screen.width - width);
  return {
    x,
    y: state.screen.y,
    width,
    height: state.screen.height,
  };
}

async function openPanel(state: RuntimeState): Promise<void> {
  const rect = panelRect(state);
  opening = true;
  await writeAction({
    v: 1,
    action: "open_shell_panel_rect",
    x: rect.x,
    y: rect.y,
    width: rect.width,
    height: rect.height,
    modal: false,
    show_border: true,
    show_controls: false,
    transparent_background: false,
  });
}

async function ensurePanelPosition(state: RuntimeState): Promise<void> {
  if (!panelId) return;
  const rect = panelRect(state);
  await writeAction({ v: 1, action: "move_panel_by_id", panel_id: panelId, x: rect.x, y: rect.y });
  await writeAction({ v: 1, action: "resize_panel_by_id", panel_id: panelId, width: rect.width, height: rect.height });
}

async function main() {
  for await (const ev of readEvents()) {
    if (isPluginConfigEvent(ev)) {
      if (ev.key === "side") {
        side = ev.value === "right" ? "right" : "left";
      } else if (ev.key === "width") {
        const n = Number.parseInt(ev.value, 10);
        if (Number.isFinite(n)) panelWidth = Math.max(12, n);
      } else if (ev.key === "persistent_process") {
        persistentProcess = parseBoolLike(ev.value);
      }
      if (lastState && panelId) {
        await ensurePanelPosition(lastState);
      }
      continue;
    }

    if (ev.event === "on_start") {
      await writeAction({ v: 1, action: "register_command", command: TOGGLE_COMMAND });
      continue;
    }

    if (isStateChangedEvent(ev)) {
      lastState = ev.state;

      if (opening && ev.state.has_focused_panel) {
        panelId = ev.state.focused_panel_id;
        opening = false;
        visible = true;
      }

      if (ev.reason === "screen") {
        await ensurePanelPosition(ev.state);
      }
      continue;
    }

    if (!isCommandEvent(ev)) continue;

    if (ev.command === TOGGLE_COMMAND) {
      if (panelId) {
        if (persistentProcess) {
          const nextVisible = !visible;
          await writeAction({ v: 1, action: "set_panel_visibility_by_id", panel_id: panelId, visible: nextVisible });
          if (nextVisible) {
            await writeAction({ v: 1, action: "focus_panel_by_id", panel_id: panelId });
          }
          visible = nextVisible;
        } else {
          await writeAction({ v: 1, action: "close_panel_by_id", panel_id: panelId });
          panelId = null;
          opening = false;
          visible = false;
        }
      } else if (lastState && !opening) {
        await openPanel(lastState);
      }
      continue;
    }
  }
}

main().catch(() => {});
