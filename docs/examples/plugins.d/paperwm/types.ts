export type LayoutType = "vertical_stack" | "horizontal_stack" | "grid" | "paperwm" | "fullscreen";
export type MouseMode = "hybrid" | "passthrough" | "compositor";

export type Rect = { x: number; y: number; width: number; height: number };

export type RuntimeState = {
  layout: LayoutType;
  window_count: number;
  minimized_window_count: number;
  visible_window_count: number;
  focused_index: number;
  has_focused_window: boolean;
  tab_count: number;
  active_tab_index: number;
  has_active_tab: boolean;
  master_count: number;
  master_ratio_permille: number;
  mouse_mode: MouseMode;
  sync_scroll_enabled: boolean;
  screen: Rect;
};

export type TickStats = {
  reads: number;
  resized: number;
  popup_updates: number;
  redraw: boolean;
  detach_requested: boolean;
  sigwinch: boolean;
  sighup: boolean;
  sigterm: boolean;
};

export type OnStartEvent = {
  v: 1;
  event: "on_start";
  layout: LayoutType;
};

export type OnLayoutChangedEvent = {
  v: 1;
  event: "on_layout_changed";
  layout: LayoutType;
};

export type OnShutdownEvent = {
  v: 1;
  event: "on_shutdown";
};

export type OnStateChangedEvent = {
  v: 1;
  event: "on_state_changed";
  reason: "layout" | "window_count" | "focus" | "tab" | "master" | "mouse_mode" | "sync_scroll" | "screen" | "state" | "start";
  state: RuntimeState;
};

export type OnTickEvent = {
  v: 1;
  event: "on_tick";
  stats: TickStats;
  state: RuntimeState;
};

export type OnComputeLayoutEvent = {
  v: 1;
  id: number;
  event: "on_compute_layout";
  params: {
    layout: LayoutType;
    screen: Rect;
    window_count: number;
    window_ids: number[];
    focused_index: number;
    master_count: number;
    master_ratio_permille: number;
    gap: number;
  };
};

export type OnPointerEvent = {
  v: 1;
  event: "on_pointer";
  pointer: {
    x: number;
    y: number;
    button: number;
    pressed: boolean;
    motion: boolean;
  };
  hit?: {
    window_id: number;
    window_index: number;
    on_title_bar: boolean;
    on_minimize_button: boolean;
    on_maximize_button: boolean;
    on_close_button: boolean;
    on_minimized_toolbar: boolean;
    on_restore_button: boolean;
  };
};

export type PluginEvent =
  | OnStartEvent
  | OnLayoutChangedEvent
  | OnShutdownEvent
  | OnStateChangedEvent
  | OnTickEvent
  | OnComputeLayoutEvent
  | OnPointerEvent;

export type ActionMessage =
  | { v: 1; action: "cycle_layout" }
  | { v: 1; action: "set_layout"; layout: LayoutType }
  | { v: 1; action: "set_master_ratio_permille"; value: number }
  | { v: 1; action: "request_redraw" }
  | { v: 1; action: "minimize_focused_window" }
  | { v: 1; action: "restore_all_minimized_windows" }
  | { v: 1; action: "move_focused_window_to_index"; index: number }
  | { v: 1; action: "close_focused_window" }
  | { v: 1; action: "restore_window_by_id"; window_id: number }
  | { v: 1; action: "set_ui_bars"; toolbar_line: string; tab_line: string; status_line: string }
  | { v: 1; action: "clear_ui_bars" };

export type LayoutResponseMessage =
  | { v: 1; id: number; rects: Rect[] }
  | { v: 1; id: number; fallback: true };

export type PluginOutput = ActionMessage | LayoutResponseMessage;
