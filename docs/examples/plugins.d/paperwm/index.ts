import {
  isComputeLayoutEvent,
  isStateChangedEvent,
  readEvents,
  writeAction,
  writeLayoutResponse,
} from "./helpers";
import type { OnComputeLayoutEvent, Rect } from "./types";

function computePaperwm(params: OnComputeLayoutEvent["params"]): Rect[] {
  const { screen, window_count, focused_index, master_ratio_permille, gap } = params;
  if (window_count <= 0) return [];

  const paneWidth = Math.max(1, Math.min(screen.width, Math.floor((screen.width * master_ratio_permille) / 1000)));
  const step = paneWidth + gap;
  const focusX = screen.x + Math.floor((screen.width - paneWidth) / 2);
  const x0 = screen.x;
  const x1 = screen.x + screen.width;

  const rects: Rect[] = [];
  for (let i = 0; i < window_count; i += 1) {
    const virtualX = focusX + (i - focused_index) * step;
    const virtualX1 = virtualX + paneWidth;
    const clipX0 = Math.max(virtualX, x0);
    const clipX1 = Math.min(virtualX1, x1);
    if (clipX1 <= clipX0) {
      rects.push({ x: screen.x, y: screen.y, width: 0, height: 0 });
      continue;
    }
    rects.push({ x: clipX0, y: screen.y, width: clipX1 - clipX0, height: screen.height });
  }
  return rects;
}

async function main() {
  for await (const ev of readEvents()) {
    if (ev.event === "on_start") {
      await writeAction({ v: 1, action: "set_layout", layout: "paperwm" });
      continue;
    }
    if (isStateChangedEvent(ev) && ev.reason === "focus" && ev.state.has_focused_window) {
      // Example of typed state event handling for plugin authors.
    }
    if (!isComputeLayoutEvent(ev)) continue;

    const rects = computePaperwm(ev.params);
    await writeLayoutResponse(ev.id, rects);
  }
}

main().catch(() => {});
