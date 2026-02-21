type Rect = { x: number; y: number; width: number; height: number };

type ComputeLayoutEvent = {
  v: 1;
  id: number;
  event: "on_compute_layout";
  params: {
    layout: string;
    screen: Rect;
    window_count: number;
    focused_index: number;
    master_count: number;
    master_ratio_permille: number;
    gap: number;
  };
};

function computePaperwm(params: ComputeLayoutEvent["params"]): Rect[] {
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
      const ev = msg as Partial<ComputeLayoutEvent>;
      if ((msg as any).event === "on_start") {
        await Bun.stdout.write(
          encoder.encode(JSON.stringify({ v: 1, action: "set_layout", layout: "paperwm" }) + "\n"),
        );
        continue;
      }
      if (ev.event !== "on_compute_layout" || typeof ev.id !== "number" || !ev.params) continue;

      const rects = computePaperwm(ev.params);
      const response = JSON.stringify({ v: 1, id: ev.id, rects }) + "\n";
      await Bun.stdout.write(encoder.encode(response));
    }
  }
}

main().catch(() => {});
