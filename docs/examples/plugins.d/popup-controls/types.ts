export type LayoutType = "vertical_stack" | "horizontal_stack" | "grid" | "paperwm" | "fullscreen";
export type MouseMode = "hybrid" | "passthrough" | "compositor";
export type CommandName =
  | "create_window"
  | "close_window"
  | "open_popup"
  | "close_popup"
  | "cycle_popup"
  | "new_tab"
  | "close_tab"
  | "next_tab"
  | "prev_tab"
  | "move_window_next_tab"
  | "next_window"
  | "prev_window"
  | "focus_left"
  | "focus_down"
  | "focus_up"
  | "focus_right"
  | "zoom_to_master"
  | "cycle_layout"
  | "resize_master_shrink"
  | "resize_master_grow"
  | "master_count_increase"
  | "master_count_decrease"
  | "scroll_page_up"
  | "scroll_page_down"
  | "toggle_sync_scroll"
  | "toggle_mouse_passthrough"
  | "detach";

export type Rect = { x: number; y: number; width: number; height: number };

export type RuntimeState = {
  layout: LayoutType;
  window_count: number;
  minimized_window_count: number;
  visible_window_count: number;
  panel_count: number;
  focused_panel_id: number;
  has_focused_panel: boolean;
  focused_index: number;
  focused_window_id: number;
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

export type OnStartEvent = { v: 1; event: "on_start"; layout: LayoutType };
export type OnLayoutChangedEvent = { v: 1; event: "on_layout_changed"; layout: LayoutType };
export type OnShutdownEvent = { v: 1; event: "on_shutdown" };

export type OnStateChangedEvent = {
  v: 1;
  event: "on_state_changed";
  reason: "layout" | "window_count" | "focus" | "tab" | "master" | "mouse_mode" | "sync_scroll" | "screen" | "state" | "start";
  state: RuntimeState;
};

export type OnTickEvent = { v: 1; event: "on_tick"; stats: TickStats; state: RuntimeState };

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
  pointer: { x: number; y: number; button: number; pressed: boolean; motion: boolean };
  hit?: {
    window_id: number;
    window_index: number;
    on_title_bar: boolean;
    on_minimize_button: boolean;
    on_maximize_button: boolean;
    on_close_button: boolean;
    on_minimized_toolbar: boolean;
    on_restore_button: boolean;
    is_panel: boolean;
    panel_id: number;
    panel_rect: Rect;
    on_panel_title_bar: boolean;
    on_panel_close_button: boolean;
    on_panel_resize_left: boolean;
    on_panel_resize_right: boolean;
    on_panel_resize_top: boolean;
    on_panel_resize_bottom: boolean;
    on_panel_body: boolean;
  };
};

export type OnCommandEvent = { v: 1; event: "on_command"; command: CommandName };

export type PluginEvent =
  | OnStartEvent
  | OnLayoutChangedEvent
  | OnShutdownEvent
  | OnStateChangedEvent
  | OnTickEvent
  | OnComputeLayoutEvent
  | OnPointerEvent
  | OnCommandEvent;

export type ActionMessage =
  | { v: 1; action: "cycle_layout" }
  | { v: 1; action: "set_layout"; layout: LayoutType }
  | { v: 1; action: "set_master_ratio_permille"; value: number }
  | { v: 1; action: "request_redraw" }
  | { v: 1; action: "minimize_focused_window" }
  | { v: 1; action: "restore_all_minimized_windows" }
  | { v: 1; action: "move_focused_window_to_index"; index: number }
  | { v: 1; action: "move_window_by_id_to_index"; window_id: number; index: number }
  | { v: 1; action: "close_focused_window" }
  | { v: 1; action: "restore_window_by_id"; window_id: number }
  | { v: 1; action: "register_command"; command: CommandName; enabled?: boolean }
  | { v: 1; action: "open_shell_panel" }
  | { v: 1; action: "close_focused_panel" }
  | { v: 1; action: "cycle_panel_focus" }
  | { v: 1; action: "toggle_shell_panel" }
  | {
      v: 1;
      action: "open_shell_panel_rect";
      x: number;
      y: number;
      width: number;
      height: number;
      modal?: boolean;
      transparent_background?: boolean;
      show_border?: boolean;
      show_controls?: boolean;
    }
  | { v: 1; action: "close_panel_by_id"; panel_id: number }
  | { v: 1; action: "focus_panel_by_id"; panel_id: number }
  | { v: 1; action: "move_panel_by_id"; panel_id: number; x: number; y: number }
  | { v: 1; action: "resize_panel_by_id"; panel_id: number; width: number; height: number }
  | {
      v: 1;
      action: "set_panel_style_by_id";
      panel_id: number;
      transparent_background?: boolean;
      show_border?: boolean;
      show_controls?: boolean;
    }
  | { v: 1; action: "set_ui_bars"; toolbar_line: string; tab_line: string; status_line: string }
  | { v: 1; action: "clear_ui_bars" };

export type LayoutResponseMessage =
  | { v: 1; id: number; rects: Rect[] }
  | { v: 1; id: number; fallback: true };

export type PluginOutput = ActionMessage | LayoutResponseMessage;
