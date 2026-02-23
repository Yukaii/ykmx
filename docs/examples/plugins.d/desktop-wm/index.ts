import {
  isComputeLayoutEvent,
  isPluginConfigEvent,
  isPointerEvent,
  isStateChangedEvent,
  readEvents,
  requestRedraw,
  writeAction,
  writeLayoutResponse,
  writeUiBars,
} from "./helpers";
import type { Rect, RuntimeState } from "./types";

type Frame = Rect;
type ResizeEdges = { left: boolean; right: boolean; top: boolean; bottom: boolean };
type DragState =
  | {
      kind: "move";
      window_id: number;
      base: Frame;
      start_x: number;
      start_y: number;
    }
  | {
      kind: "resize";
      window_id: number;
      base: Frame;
      start_x: number;
      start_y: number;
      edges: ResizeEdges;
    };

const MIN_W = 18;
const MIN_H = 6;
const RESIZE_EDGE = 1;
const LAYOUT_LABEL = "desktop-wm";

const frames = new Map<number, Frame>();
const maximizedFrames = new Map<number, Frame>();
let lastState: RuntimeState | null = null;
let drag: DragState | null = null;
let lastFocusedWindowId: number | null = null;
let lastWindowIds: number[] = [];
let startMaximized = true;

function parseBoolLike(value: string): boolean {
  const s = value.trim().toLowerCase();
  return s === "1" || s === "true" || s === "yes" || s === "on";
}

function trimToWidth(text: string, width: number): string {
  if (width <= 0) return "";
  if (text.length <= width) return text;
  if (width <= 3) return ".".repeat(width);
  return `${text.slice(0, width - 3)}...`;
}

function fitLeft(text: string, width: number): string {
  const t = trimToWidth(text, width);
  if (t.length >= width) return t;
  return `${t}${" ".repeat(width - t.length)}`;
}

function fitLeftRight(left: string, right: string, width: number): string {
  if (width <= 0) return "";
  const r = trimToWidth(right, Math.floor(width * 0.5));
  if (left.length + 1 + r.length <= width) {
    return `${left}${" ".repeat(width - left.length - r.length)}${r}`;
  }
  const l = trimToWidth(left, width - (r.length > 0 ? r.length + 1 : 0));
  if (l.length + r.length <= width) {
    return `${l}${" ".repeat(width - l.length - r.length)}${r}`;
  }
  return fitLeft(`${l} ${r}`.trim(), width);
}

function renderBars(state: RuntimeState): { toolbar: string; tab: string; status: string } {
  const width = Math.max(1, state.screen.width);
  const focusedId = state.has_focused_window && state.focused_index >= 0 && state.focused_index < lastWindowIds.length
    ? lastWindowIds[state.focused_index]
    : 0;

  const toolbar = "";

  const tabLeft = `tab ${state.active_tab_index + 1}/${state.tab_count} | focus:${state.has_focused_window ? state.focused_index + 1 : 0}${focusedId ? `(#${focusedId})` : ""} | layout:${LAYOUT_LABEL}`;
  const tabRight = "[click title=raise] [drag=move] [edge=resize]";
  const tab = fitLeftRight(tabLeft, tabRight, width);

  const statusLeft = `mouse:${state.mouse_mode} scroll-mode:${state.scrollback_mode_enabled ? "on" : "off"} screen:${state.screen.width}x${state.screen.height}`;
  const statusRight = "keys: Ctrl+G h/j/k/l focus, Space cycle";
  const status = fitLeftRight(statusLeft, statusRight, width);
  return { toolbar, tab, status };
}

function defaultFrame(screen: Rect, idx: number): Frame {
  const w = Math.max(MIN_W, Math.floor(screen.width * 0.55));
  const h = Math.max(MIN_H, Math.floor(screen.height * 0.7));
  const x = screen.x + Math.max(0, Math.floor((screen.width - w) / 2)) + (idx % 8) * 2;
  const y = screen.y + Math.max(0, Math.floor((screen.height - h) / 2)) + (idx % 6);
  return clampFrame({ x, y, width: w, height: h }, screen);
}

function clampFrame(frame: Frame, screen: Rect): Frame {
  const maxW = Math.max(MIN_W, screen.width);
  const maxH = Math.max(MIN_H, screen.height);
  const width = Math.max(MIN_W, Math.min(frame.width, maxW));
  const height = Math.max(MIN_H, Math.min(frame.height, maxH));
  const maxX = screen.x + Math.max(0, screen.width - width);
  const maxY = screen.y + Math.max(0, screen.height - height);
  const x = Math.min(Math.max(frame.x, screen.x), maxX);
  const y = Math.min(Math.max(frame.y, screen.y), maxY);
  return { x, y, width, height };
}

function syncFrames(windowIds: number[], screen: Rect): void {
  // Keep non-visible window frames so minimize/restore brings windows back
  // to their last floating geometry.
  for (let i = 0; i < windowIds.length; i += 1) {
    const id = windowIds[i];
    if (!frames.has(id)) {
      const base = defaultFrame(screen, i);
      if (startMaximized) {
        maximizedFrames.set(id, base);
        frames.set(id, {
          x: screen.x,
          y: screen.y,
          width: screen.width,
          height: screen.height,
        });
      } else {
        frames.set(id, base);
      }
    } else {
      frames.set(id, clampFrame(frames.get(id) as Frame, screen));
      if (maximizedFrames.has(id)) {
        maximizedFrames.set(id, clampFrame(maximizedFrames.get(id) as Frame, screen));
      }
    }
  }
}

function edgeHit(px: number, py: number, frame: Frame): ResizeEdges {
  const left = px >= frame.x && px < frame.x + RESIZE_EDGE;
  const right = px < frame.x + frame.width && px >= frame.x + frame.width - RESIZE_EDGE;
  const top = py >= frame.y && py < frame.y + RESIZE_EDGE;
  const bottom = py < frame.y + frame.height && py >= frame.y + frame.height - RESIZE_EDGE;
  return { left, right, top, bottom };
}

function hasEdge(edges: ResizeEdges): boolean {
  return edges.left || edges.right || edges.top || edges.bottom;
}

function resizeFrame(base: Frame, edges: ResizeEdges, dx: number, dy: number, screen: Rect): Frame {
  let x = base.x;
  let y = base.y;
  let width = base.width;
  let height = base.height;

  if (edges.left) {
    x = base.x + dx;
    width = base.width - dx;
  }
  if (edges.right) {
    width = base.width + dx;
  }
  if (edges.top) {
    y = base.y + dy;
    height = base.height - dy;
  }
  if (edges.bottom) {
    height = base.height + dy;
  }

  if (width < MIN_W) {
    if (edges.left) x -= MIN_W - width;
    width = MIN_W;
  }
  if (height < MIN_H) {
    if (edges.top) y -= MIN_H - height;
    height = MIN_H;
  }

  return clampFrame({ x, y, width, height }, screen);
}

async function maybeBringToFront(windowId: number, windowIndex: number): Promise<void> {
  if (!lastState) return;
  const topIndex = Math.max(0, lastState.window_count - 1);
  if (windowIndex < topIndex) {
    await writeAction({ v: 1, action: "move_window_by_id_to_index", window_id: windowId, index: topIndex });
  }
}

async function maybeBringFocusedToFront(state: RuntimeState): Promise<void> {
  if (!state.has_focused_window) {
    lastFocusedWindowId = null;
    return;
  }
  const focusedWindowId = state.focused_window_id;
  if (!focusedWindowId) return;
  if (focusedWindowId === lastFocusedWindowId) return;
  const visibleIndex = lastWindowIds.indexOf(focusedWindowId);
  if (visibleIndex < 0) return;
  lastFocusedWindowId = focusedWindowId;
  await maybeBringToFront(focusedWindowId, visibleIndex);
}

function applyDrag(px: number, py: number): boolean {
  if (!drag || !lastState) return false;

  const dx = px - drag.start_x;
  const dy = py - drag.start_y;
  maximizedFrames.delete(drag.window_id);
  if (drag.kind === "move") {
    const next = clampFrame(
      {
        x: drag.base.x + dx,
        y: drag.base.y + dy,
        width: drag.base.width,
        height: drag.base.height,
      },
      lastState.screen,
    );
    frames.set(drag.window_id, next);
    return true;
  }

  const next = resizeFrame(drag.base, drag.edges, dx, dy, lastState.screen);
  frames.set(drag.window_id, next);
  return true;
}

async function main() {
  for await (const ev of readEvents()) {
    if (ev.event === "on_start") continue;

    if (isPluginConfigEvent(ev)) {
      if (ev.key === "start_maximized") {
        startMaximized = parseBoolLike(ev.value);
      }
      continue;
    }

    if (isStateChangedEvent(ev)) {
      lastState = ev.state;
      const bars = renderBars(ev.state);
      await writeUiBars(bars.toolbar, bars.tab, bars.status);
      await maybeBringFocusedToFront(ev.state);
      continue;
    }

    if (isComputeLayoutEvent(ev)) {
      const { screen, window_ids } = ev.params;
      lastWindowIds = window_ids.slice();
      syncFrames(window_ids, screen);
      const rects = window_ids.map((id, i) => clampFrame(frames.get(id) ?? defaultFrame(screen, i), screen));
      await writeLayoutResponse(ev.id, rects);
      continue;
    }

    if (!isPointerEvent(ev)) continue;

    if (ev.pointer.pressed && ev.pointer.motion && drag) {
      if (applyDrag(ev.pointer.x, ev.pointer.y)) {
        await requestRedraw();
      }
      continue;
    }

    if (!ev.pointer.pressed) {
      const hadDrag = drag !== null;
      drag = null;
      if (hadDrag) await requestRedraw();
      continue;
    }

    if (!ev.hit || ev.pointer.button !== 0 || ev.pointer.motion) continue;

    if (ev.hit.on_restore_button) {
      await writeAction({ v: 1, action: "restore_window_by_id", window_id: ev.hit.window_id });
      await maybeBringToFront(ev.hit.window_id, ev.hit.window_index);
      lastFocusedWindowId = ev.hit.window_id;
      continue;
    }
    if (ev.hit.on_close_button) {
      frames.delete(ev.hit.window_id);
      maximizedFrames.delete(ev.hit.window_id);
      await writeAction({ v: 1, action: "close_focused_window" });
      continue;
    }
    if (ev.hit.on_minimize_button) {
      await writeAction({ v: 1, action: "minimize_focused_window" });
      continue;
    }
    if (ev.hit.on_maximize_button) {
      if (!lastState) continue;
      const current = frames.get(ev.hit.window_id);
      if (!current) continue;
      if (maximizedFrames.has(ev.hit.window_id)) {
        const restore = maximizedFrames.get(ev.hit.window_id) as Frame;
        frames.set(ev.hit.window_id, clampFrame(restore, lastState.screen));
        maximizedFrames.delete(ev.hit.window_id);
      } else {
        maximizedFrames.set(ev.hit.window_id, { ...current });
        frames.set(ev.hit.window_id, {
          x: lastState.screen.x,
          y: lastState.screen.y,
          width: lastState.screen.width,
          height: lastState.screen.height,
        });
      }
      await requestRedraw();
      continue;
    }

    await maybeBringToFront(ev.hit.window_id, ev.hit.window_index);

    const frame = frames.get(ev.hit.window_id);
    if (!frame) continue;

    if (ev.hit.on_title_bar) {
      drag = {
        kind: "move",
        window_id: ev.hit.window_id,
        base: frame,
        start_x: ev.pointer.x,
        start_y: ev.pointer.y,
      };
      continue;
    }

    const edges = edgeHit(ev.pointer.x, ev.pointer.y, frame);
    if (hasEdge(edges)) {
      drag = {
        kind: "resize",
        window_id: ev.hit.window_id,
        base: frame,
        start_x: ev.pointer.x,
        start_y: ev.pointer.y,
        edges,
      };
    }
  }
}

main().catch(() => {});
