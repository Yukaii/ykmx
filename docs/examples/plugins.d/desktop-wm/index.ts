import { isPointerEvent, isStateChangedEvent, readEvents, writeAction } from "./helpers";
import type { LayoutType } from "./types";

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
      continue;
    }
    if (!isPointerEvent(ev)) continue;

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
