import { isPointerEvent, isStateChangedEvent, readEvents, writeAction, writeUiBars } from "./helpers";
import type { LayoutType, RuntimeState } from "./types";

function renderBars(state: RuntimeState): { toolbar: string; tab: string; status: string } {
  const toolbar = `desk: minimized=${state.minimized_window_count} visible=${state.visible_window_count} windows=${state.window_count}`;
  const tab = `tab:${state.active_tab_index + 1}/${state.tab_count} layout=${state.layout} focus=${state.has_focused_window ? state.focused_index + 1 : 0}`;
  const status = `mouse=${state.mouse_mode} sync=${state.sync_scroll_enabled ? "on" : "off"} ratio=${state.master_ratio_permille} screen=${state.screen.width}x${state.screen.height}`;
  return { toolbar, tab, status };
}

async function main() {
  let dragSourceIndex: number | null = null;
  let lastNonFullscreenLayout: LayoutType = "paperwm";
  let currentLayout: LayoutType = "paperwm";

  for await (const ev of readEvents()) {
    if (ev.event === "on_start") {
      currentLayout = ev.layout;
      if (ev.layout !== "fullscreen") lastNonFullscreenLayout = ev.layout;
      continue;
    }
    if (isStateChangedEvent(ev)) {
      currentLayout = ev.state.layout;
      if (ev.state.layout !== "fullscreen") lastNonFullscreenLayout = ev.state.layout;
      const bars = renderBars(ev.state);
      await writeUiBars(bars.toolbar, bars.tab, bars.status);
      continue;
    }
    if (!isPointerEvent(ev)) continue;

    if (ev.hit?.on_restore_button && ev.pointer.pressed && !ev.pointer.motion && ev.pointer.button === 0) {
      await writeAction({ v: 1, action: "restore_window_by_id", window_id: ev.hit.window_id });
      continue;
    }

    if (ev.hit?.on_close_button && ev.pointer.pressed && !ev.pointer.motion && ev.pointer.button === 0) {
      await writeAction({ v: 1, action: "close_focused_window" });
      continue;
    }
    if (ev.hit?.on_minimize_button && ev.pointer.pressed && !ev.pointer.motion && ev.pointer.button === 0) {
      await writeAction({ v: 1, action: "minimize_focused_window" });
      continue;
    }
    if (ev.hit?.on_maximize_button && ev.pointer.pressed && !ev.pointer.motion && ev.pointer.button === 0) {
      if (currentLayout === "fullscreen") {
        await writeAction({ v: 1, action: "set_layout", layout: lastNonFullscreenLayout });
      } else {
        await writeAction({ v: 1, action: "set_layout", layout: "fullscreen" });
      }
      continue;
    }

    if (ev.hit?.on_title_bar && ev.pointer.pressed && !ev.pointer.motion && ev.pointer.button === 0) {
      dragSourceIndex = ev.hit.window_index;
      continue;
    }
    if (!ev.pointer.pressed && dragSourceIndex !== null && ev.hit?.on_title_bar) {
      if (ev.hit.window_index !== dragSourceIndex) {
        await writeAction({ v: 1, action: "move_focused_window_to_index", index: ev.hit.window_index });
      }
      dragSourceIndex = null;
      continue;
    }
    if (!ev.pointer.pressed) {
      dragSourceIndex = null;
    }
  }
}

main().catch(() => {});
