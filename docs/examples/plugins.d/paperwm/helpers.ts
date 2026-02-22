import type {
  ActionMessage,
  LayoutResponseMessage,
  OnComputeLayoutEvent,
  OnStateChangedEvent,
  OnPointerEvent,
  OnCommandEvent,
  OnTickEvent,
  PluginEvent,
  PluginOutput,
  Rect,
} from "./types";

const encoder = new TextEncoder();

export function isComputeLayoutEvent(ev: PluginEvent): ev is OnComputeLayoutEvent {
  return ev.event === "on_compute_layout";
}

export function isStateChangedEvent(ev: PluginEvent): ev is OnStateChangedEvent {
  return ev.event === "on_state_changed";
}

export function isTickEvent(ev: PluginEvent): ev is OnTickEvent {
  return ev.event === "on_tick";
}

export function isPointerEvent(ev: PluginEvent): ev is OnPointerEvent {
  return ev.event === "on_pointer";
}

export function isCommandEvent(ev: PluginEvent): ev is OnCommandEvent {
  return ev.event === "on_command";
}

export async function writeOutput(msg: PluginOutput): Promise<void> {
  await Bun.stdout.write(encoder.encode(JSON.stringify(msg) + "\n"));
}

export async function writeAction(msg: ActionMessage): Promise<void> {
  await writeOutput(msg);
}

export async function requestRedraw(): Promise<void> {
  await writeAction({ v: 1, action: "request_redraw" });
}

export async function writeUiBars(
  toolbar_line: string,
  tab_line: string,
  status_line: string,
): Promise<void> {
  await writeAction({ v: 1, action: "set_ui_bars", toolbar_line, tab_line, status_line });
}

export async function clearUiBars(): Promise<void> {
  await writeAction({ v: 1, action: "clear_ui_bars" });
}

export async function writeLayoutResponse(
  id: number,
  rects: Rect[],
): Promise<void> {
  const msg: LayoutResponseMessage = { v: 1, id, rects };
  await writeOutput(msg);
}

export async function writeLayoutFallback(id: number): Promise<void> {
  const msg: LayoutResponseMessage = { v: 1, id, fallback: true };
  await writeOutput(msg);
}

export async function* readEvents(): AsyncGenerator<PluginEvent, void, unknown> {
  const decoder = new TextDecoder();
  let buf = "";
  for await (const chunk of Bun.stdin.stream()) {
    buf += decoder.decode(chunk, { stream: true });
    while (true) {
      const nl = buf.indexOf("\n");
      if (nl < 0) break;
      const line = buf.slice(0, nl);
      buf = buf.slice(nl + 1);
      if (!line.trim()) continue;

      let parsed: unknown;
      try {
        parsed = JSON.parse(line);
      } catch {
        continue;
      }
      if (typeof parsed !== "object" || parsed === null) continue;
      yield parsed as PluginEvent;
    }
  }
}
