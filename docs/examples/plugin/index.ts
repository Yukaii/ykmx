import type { OnComputeLayoutEvent, PluginEvent, PluginOutput, Rect } from "./types";

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

const decoder = new TextDecoder();
const encoder = new TextEncoder();
let buf = "";

async function main() {
  for await (const chunk of Bun.stdin.stream()) {
    buf += decoder.decode(chunk, { stream: true });
    while (true) {
      const nl = buf.indexOf("\n");
      if (nl < 0) break;
      const line = buf.slice(0, nl);
      buf = buf.slice(nl + 1);
      if (!line.trim()) continue;

      let msg: unknown;
      try {
        msg = JSON.parse(line);
      } catch {
        continue;
      }

      if (typeof msg !== "object" || msg === null) continue;
      const ev = msg as PluginEvent;
      if (ev.event === "on_start") {
        const setLayout: PluginOutput = { v: 1, action: "set_layout", layout: "paperwm" };
        await Bun.stdout.write(
          encoder.encode(JSON.stringify(setLayout) + "\n"),
        );
        continue;
      }
      if (ev.event === "on_state_changed" && ev.reason === "focus" && ev.state.has_focused_window) {
        // Example of typed state event handling for plugin authors.
      }
      if (ev.event !== "on_compute_layout") continue;

      const rects = computePaperwm(ev.params);
      const response: PluginOutput = { v: 1, id: ev.id, rects };
      await Bun.stdout.write(encoder.encode(JSON.stringify(response) + "\n"));
    }
  }
}

main().catch(() => {});
