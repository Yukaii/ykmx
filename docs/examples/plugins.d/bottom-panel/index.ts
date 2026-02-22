import { isCommandEvent, isPluginConfigEvent, isStateChangedEvent, readEvents, writeAction } from "./helpers";
import type { RuntimeState } from "./types";

const DEFAULT_HEIGHT = 10;
let panelHeight = DEFAULT_HEIGHT;
const TOGGLE_COMMAND = "panel.bottom.toggle";

let panelId: number | null = null;
let opening = false;
let lastState: RuntimeState | null = null;

function panelRect(state: RuntimeState): { x: number; y: number; width: number; height: number } {
  const height = Math.max(4, Math.min(panelHeight, state.screen.height));
  return {
    x: state.screen.x,
    y: state.screen.y + Math.max(0, state.screen.height - height),
    width: state.screen.width,
    height,
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
      if (ev.key === "height") {
        const n = Number.parseInt(ev.value, 10);
        if (Number.isFinite(n)) panelHeight = Math.max(4, n);
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
      }

      if (panelId && ev.state.panel_count === 0) {
        panelId = null;
      }

      if (ev.reason === "screen") {
        await ensurePanelPosition(ev.state);
      }
      continue;
    }

    if (!isCommandEvent(ev)) continue;

    if (ev.command === TOGGLE_COMMAND) {
      if (panelId) {
        await writeAction({ v: 1, action: "close_panel_by_id", panel_id: panelId });
        panelId = null;
        opening = false;
      } else if (lastState && !opening) {
        await openPanel(lastState);
      }
      continue;
    }
  }
}

main().catch(() => {});
