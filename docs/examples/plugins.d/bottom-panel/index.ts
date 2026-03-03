import { isCommandEvent, isPluginConfigEvent, isStateChangedEvent, readEvents, writeAction } from "./helpers";
import type { RuntimeState } from "./types";

const DEFAULT_HEIGHT = 10;
const DEFAULT_HEIGHT_PCT = 25; // 25% of screen height

// Support both absolute (height) and percentage (height_pct) dimensions.
// If height_pct is non-null, it takes precedence over height.
let panelHeight: number | null = DEFAULT_HEIGHT;
let panelHeightPct: number | null = null;
const TOGGLE_COMMAND = "panel.bottom.toggle";
let persistentProcess = true;

let panelId: number | null = null;
let opening = false;
let visible = false;
let lastState: RuntimeState | null = null;

function parseBoolLike(value: string): boolean {
  const s = value.trim().toLowerCase();
  return s === "1" || s === "true" || s === "yes" || s === "on";
}

function panelRect(state: RuntimeState): { x: number; y: number; width: number; height: number; height_pct: number | null } {
  // Use percentage if set, otherwise fall back to absolute height
  const effectiveHeight = panelHeightPct !== null
    ? Math.max(4, Math.floor((panelHeightPct / 100) * state.screen.height))
    : Math.max(4, Math.min(panelHeight ?? DEFAULT_HEIGHT, state.screen.height));
  return {
    x: state.screen.x,
    y: state.screen.y + Math.max(0, state.screen.height - effectiveHeight),
    width: state.screen.width,
    height: effectiveHeight,
    height_pct: panelHeightPct,
  };
}

async function openPanel(state: RuntimeState): Promise<void> {
  const rect = panelRect(state);
  opening = true;
  // Build action with either absolute or percentage height
  const action: Record<string, unknown> = {
    v: 1,
    action: "open_shell_panel_rect",
    x: rect.x,
    y: rect.y,
    width: rect.width,
    modal: false,
    show_border: true,
    show_controls: false,
    transparent_background: false,
  };
  if (rect.height_pct !== null) {
    action.height_pct = rect.height_pct;
  } else {
    action.height = rect.height;
  }
  await writeAction(action);
}

async function ensurePanelPosition(state: RuntimeState): Promise<void> {
  if (!panelId) return;
  const rect = panelRect(state);
  await writeAction({ v: 1, action: "move_panel_by_id", panel_id: panelId, x: rect.x, y: rect.y });
  // Use percentage-based resize when configured
  if (rect.height_pct !== null) {
    await writeAction({ v: 1, action: "resize_panel_by_id", panel_id: panelId, width: rect.width, height_pct: rect.height_pct });
  } else {
    await writeAction({ v: 1, action: "resize_panel_by_id", panel_id: panelId, width: rect.width, height: rect.height });
  }
}

async function main() {
  for await (const ev of readEvents()) {
    if (isPluginConfigEvent(ev)) {
      if (ev.key === "height") {
        const n = Number.parseInt(ev.value, 10);
        if (Number.isFinite(n)) {
          panelHeight = Math.max(4, n);
          panelHeightPct = null; // Clear percentage when absolute is set
        }
      } else if (ev.key === "height_pct") {
        const n = Number.parseInt(ev.value, 10);
        if (Number.isFinite(n)) {
          panelHeightPct = Math.max(1, Math.min(100, n));
          panelHeight = null; // Clear absolute when percentage is set
        }
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
