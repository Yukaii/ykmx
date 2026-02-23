const layout = @import("layout.zig");
const multiplexer = @import("multiplexer.zig");
const plugin_host = @import("plugin_host.zig");
const runtime_sgr = @import("runtime_sgr.zig");

pub const RequestRedrawTraceFn = *const fn (screen: layout.Rect) void;

pub fn applyPluginAction(
    mux: *multiplexer.Multiplexer,
    screen: layout.Rect,
    plugin_name: []const u8,
    action: plugin_host.PluginHost.Action,
    request_redraw_trace: ?RequestRedrawTraceFn,
) !bool {
    switch (action) {
        .cycle_layout => {
            _ = try mux.workspace_mgr.cycleActiveLayout();
            _ = try mux.resizeActiveWindowsToLayout(screen);
            return true;
        },
        .set_layout => |layout_type| {
            try mux.workspace_mgr.setActiveLayout(layout_type);
            _ = try mux.resizeActiveWindowsToLayout(screen);
            return true;
        },
        .set_master_ratio_permille => |value| {
            const clamped: u16 = @intCast(@max(@as(u32, 100), @min(@as(u32, 900), value)));
            try mux.workspace_mgr.setActiveMasterRatioPermille(clamped);
            _ = try mux.resizeActiveWindowsToLayout(screen);
            return true;
        },
        .request_redraw => {
            if (request_redraw_trace) |trace_fn| trace_fn(screen);
            _ = try mux.resizeActiveWindowsToLayout(screen);
            return true;
        },
        .minimize_focused_window => return try mux.minimizeFocusedWindow(screen),
        .restore_all_minimized_windows => return (try mux.restoreAllMinimizedWindows(screen)) > 0,
        .move_focused_window_to_index => |index| return try mux.moveFocusedWindowToIndex(index, screen),
        .move_window_by_id_to_index => |payload| return try mux.moveWindowByIdToIndex(payload.window_id, payload.index, screen),
        .close_focused_window => {
            _ = mux.closeFocusedWindow() catch |err| switch (err) {
                error.NoFocusedWindow => return false,
                else => return err,
            };
            _ = try mux.resizeActiveWindowsToLayout(screen);
            return true;
        },
        .restore_window_by_id => |window_id| return try mux.restoreWindowById(window_id, screen),
        .register_command => |payload| {
            try mux.setPluginCommandOverride(payload.command, payload.enabled);
            return false;
        },
        .register_command_name => |payload| {
            try mux.setPluginNamedCommandOverride(payload.command_name, payload.enabled);
            return false;
        },
        .open_shell_panel => {
            _ = try mux.openShellPopupOwned("popup-shell", screen, true, plugin_name);
            return true;
        },
        .close_focused_panel => return try mux.closeFocusedPopupOwned(plugin_name),
        .cycle_panel_focus => return mux.cyclePopupFocusOwned(plugin_name),
        .toggle_shell_panel => {
            if (try mux.closeFocusedPopupOwned(plugin_name)) {
                return true;
            } else {
                _ = try mux.openShellPopupOwned("popup-shell", screen, true, plugin_name);
            }
            return true;
        },
        .open_shell_panel_rect => |payload| {
            _ = try mux.openShellPopupRectStyled(
                "popup-shell",
                screen,
                .{ .x = payload.x, .y = payload.y, .width = payload.width, .height = payload.height },
                payload.modal,
                .{
                    .transparent_background = payload.transparent_background,
                    .show_border = payload.show_border,
                    .show_controls = payload.show_controls,
                },
                plugin_name,
            );
            return true;
        },
        .close_panel_by_id => |panel_id| return try mux.closePopupByIdOwned(panel_id, plugin_name),
        .focus_panel_by_id => |panel_id| return try mux.focusPopupByIdOwned(panel_id, plugin_name),
        .move_panel_by_id => |payload| return try mux.movePopupByIdOwned(payload.panel_id, payload.x, payload.y, screen, plugin_name),
        .resize_panel_by_id => |payload| return try mux.resizePopupByIdOwned(payload.panel_id, payload.width, payload.height, screen, plugin_name),
        .set_panel_visibility_by_id => |payload| return try mux.setPopupVisibilityByIdOwned(payload.panel_id, payload.visible, plugin_name),
        .set_panel_style_by_id => |payload| {
            return try mux.setPopupStyleByIdOwned(payload.panel_id, .{
                .transparent_background = payload.transparent_background,
                .show_border = payload.show_border,
                .show_controls = payload.show_controls,
            }, screen, plugin_name);
        },
        .set_chrome_theme => |payload| {
            mux.applyChromeTheme(.{
                .window_minimize_char = payload.window_minimize_char,
                .window_maximize_char = payload.window_maximize_char,
                .window_close_char = payload.window_close_char,
                .focus_marker = payload.focus_marker,
                .border_horizontal = payload.border_horizontal,
                .border_vertical = payload.border_vertical,
                .border_corner_tl = payload.border_corner_tl,
                .border_corner_tr = payload.border_corner_tr,
                .border_corner_bl = payload.border_corner_bl,
                .border_corner_br = payload.border_corner_br,
                .border_tee_top = payload.border_tee_top,
                .border_tee_bottom = payload.border_tee_bottom,
                .border_tee_left = payload.border_tee_left,
                .border_tee_right = payload.border_tee_right,
                .border_cross = payload.border_cross,
            });
            return true;
        },
        .reset_chrome_theme => {
            mux.resetChromeTheme();
            return true;
        },
        .set_chrome_style => |payload| {
            mux.applyChromeStyle(.{
                .active_title = if (payload.active_title_sgr) |s| try runtime_sgr.parseSgrStyleSpec(s) else null,
                .inactive_title = if (payload.inactive_title_sgr) |s| try runtime_sgr.parseSgrStyleSpec(s) else null,
                .active_border = if (payload.active_border_sgr) |s| try runtime_sgr.parseSgrStyleSpec(s) else null,
                .inactive_border = if (payload.inactive_border_sgr) |s| try runtime_sgr.parseSgrStyleSpec(s) else null,
                .active_buttons = if (payload.active_buttons_sgr) |s| try runtime_sgr.parseSgrStyleSpec(s) else null,
                .inactive_buttons = if (payload.inactive_buttons_sgr) |s| try runtime_sgr.parseSgrStyleSpec(s) else null,
            });
            return true;
        },
        .set_panel_chrome_style_by_id => |payload| {
            return try mux.setPanelChromeStyleByIdOwned(
                payload.panel_id,
                payload.reset,
                .{
                    .active_title = if (payload.active_title_sgr) |s| try runtime_sgr.parseSgrStyleSpec(s) else null,
                    .inactive_title = if (payload.inactive_title_sgr) |s| try runtime_sgr.parseSgrStyleSpec(s) else null,
                    .active_border = if (payload.active_border_sgr) |s| try runtime_sgr.parseSgrStyleSpec(s) else null,
                    .inactive_border = if (payload.inactive_border_sgr) |s| try runtime_sgr.parseSgrStyleSpec(s) else null,
                    .active_buttons = if (payload.active_buttons_sgr) |s| try runtime_sgr.parseSgrStyleSpec(s) else null,
                    .inactive_buttons = if (payload.inactive_buttons_sgr) |s| try runtime_sgr.parseSgrStyleSpec(s) else null,
                },
                plugin_name,
            );
        },
    }
}
