const std = @import("std");
const layout = @import("layout.zig");
const multiplexer = @import("multiplexer.zig");
const plugin_host = @import("plugin_host.zig");

pub fn collectPluginRuntimeState(
    mux: *multiplexer.Multiplexer,
    screen: layout.Rect,
) !plugin_host.PluginHost.RuntimeState {
    const layout_type = try mux.workspace_mgr.activeLayoutType();
    const tab = try mux.workspace_mgr.activeTab();
    const window_count = tab.windows.items.len;
    var minimized_count: usize = 0;
    for (tab.windows.items) |w| {
        if (w.minimized) minimized_count += 1;
    }
    const focus_idx = mux.workspace_mgr.focusedWindowIndexActive() catch null;
    const focus_id = mux.workspace_mgr.focusedWindowIdActive() catch null;
    const focused_panel_id = mux.popup_mgr.focused_popup_id orelse 0;
    const master_count = try mux.workspace_mgr.activeMasterCount();
    const master_ratio = try mux.workspace_mgr.activeMasterRatioPermille();
    const active_tab_idx = mux.workspace_mgr.activeTabIndex();

    return .{
        .layout = @tagName(layout_type),
        .window_count = window_count,
        .minimized_window_count = minimized_count,
        .visible_window_count = window_count - minimized_count,
        .panel_count = mux.popup_mgr.visibleCount(),
        .focused_panel_id = focused_panel_id,
        .has_focused_panel = mux.popup_mgr.focused_popup_id != null,
        .focused_index = focus_idx orelse 0,
        .focused_window_id = focus_id orelse 0,
        .has_focused_window = focus_idx != null,
        .tab_count = mux.workspace_mgr.tabCount(),
        .active_tab_index = active_tab_idx orelse 0,
        .has_active_tab = active_tab_idx != null,
        .master_count = master_count,
        .master_ratio_permille = master_ratio,
        .mouse_mode = @tagName(mux.mouseMode()),
        .scrollback_mode_enabled = mux.scrollbackModeEnabled(),
        .screen = screen,
    };
}

pub fn pluginRuntimeStateEql(
    a: plugin_host.PluginHost.RuntimeState,
    b: plugin_host.PluginHost.RuntimeState,
) bool {
    return std.mem.eql(u8, a.layout, b.layout) and
        a.window_count == b.window_count and
        a.minimized_window_count == b.minimized_window_count and
        a.visible_window_count == b.visible_window_count and
        a.panel_count == b.panel_count and
        a.focused_panel_id == b.focused_panel_id and
        a.has_focused_panel == b.has_focused_panel and
        a.focused_index == b.focused_index and
        a.focused_window_id == b.focused_window_id and
        a.has_focused_window == b.has_focused_window and
        a.tab_count == b.tab_count and
        a.active_tab_index == b.active_tab_index and
        a.has_active_tab == b.has_active_tab and
        a.master_count == b.master_count and
        a.master_ratio_permille == b.master_ratio_permille and
        std.mem.eql(u8, a.mouse_mode, b.mouse_mode) and
        a.scrollback_mode_enabled == b.scrollback_mode_enabled and
        std.meta.eql(a.screen, b.screen);
}

pub fn detectStateChangeReason(
    prev: plugin_host.PluginHost.RuntimeState,
    next: plugin_host.PluginHost.RuntimeState,
) []const u8 {
    if (!std.mem.eql(u8, prev.layout, next.layout)) return "layout";
    if (prev.window_count != next.window_count) return "window_count";
    if (prev.minimized_window_count != next.minimized_window_count or prev.visible_window_count != next.visible_window_count) return "window_count";
    if (prev.panel_count != next.panel_count or prev.focused_panel_id != next.focused_panel_id or prev.has_focused_panel != next.has_focused_panel) return "focus";
    if (prev.focused_index != next.focused_index or prev.focused_window_id != next.focused_window_id or prev.has_focused_window != next.has_focused_window) return "focus";
    if (prev.tab_count != next.tab_count or prev.active_tab_index != next.active_tab_index or prev.has_active_tab != next.has_active_tab) return "tab";
    if (prev.master_count != next.master_count or prev.master_ratio_permille != next.master_ratio_permille) return "master";
    if (!std.mem.eql(u8, prev.mouse_mode, next.mouse_mode)) return "mouse_mode";
    if (prev.scrollback_mode_enabled != next.scrollback_mode_enabled) return "scrollback_mode";
    if (!std.meta.eql(prev.screen, next.screen)) return "screen";
    return "state";
}
