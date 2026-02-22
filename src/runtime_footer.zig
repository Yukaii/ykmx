const std = @import("std");
const layout = @import("layout.zig");
const multiplexer = @import("multiplexer.zig");
const plugin_host = @import("plugin_host.zig");
const status = @import("status.zig");
const workspace = @import("workspace.zig");

pub const FooterLines = struct {
    minimized_line: []const u8,
    tab_line: []const u8,
    status_line: []const u8,
    owned_minimized_line: ?[]u8 = null,
    owned_tab_line: ?[]u8 = null,
    owned_status_line: ?[]u8 = null,

    pub fn deinit(self: FooterLines, allocator: std.mem.Allocator) void {
        if (self.owned_minimized_line) |line| allocator.free(line);
        if (self.owned_tab_line) |line| allocator.free(line);
        if (self.owned_status_line) |line| allocator.free(line);
    }
};

pub fn resolveFooterLines(
    allocator: std.mem.Allocator,
    mux: *multiplexer.Multiplexer,
    plugin_ui_bars: ?plugin_host.PluginHost.UiBarsView,
) !FooterLines {
    var lines: FooterLines = .{
        .minimized_line = "",
        .tab_line = "",
        .status_line = "",
    };

    if (plugin_ui_bars) |ui| {
        if (ui.toolbar_line.len > 0) {
            lines.minimized_line = ui.toolbar_line;
        } else {
            lines.owned_minimized_line = try renderMinimizedToolbarLine(allocator, &mux.workspace_mgr);
            lines.minimized_line = lines.owned_minimized_line.?;
        }

        if (ui.tab_line.len > 0) {
            lines.tab_line = ui.tab_line;
        } else {
            lines.owned_tab_line = try status.renderTabBar(allocator, &mux.workspace_mgr);
            lines.tab_line = lines.owned_tab_line.?;
        }

        if (ui.status_line.len > 0) {
            lines.status_line = ui.status_line;
        } else {
            lines.owned_status_line = try status.renderStatusBarWithScrollAndSync(
                allocator,
                &mux.workspace_mgr,
                mux.focusedScrollOffset(),
                mux.syncScrollEnabled(),
            );
            lines.status_line = lines.owned_status_line.?;
        }
        return lines;
    }

    lines.owned_minimized_line = try renderMinimizedToolbarLine(allocator, &mux.workspace_mgr);
    lines.minimized_line = lines.owned_minimized_line.?;
    lines.owned_tab_line = try status.renderTabBar(allocator, &mux.workspace_mgr);
    lines.tab_line = lines.owned_tab_line.?;
    lines.owned_status_line = try status.renderStatusBarWithScrollAndSync(
        allocator,
        &mux.workspace_mgr,
        mux.focusedScrollOffset(),
        mux.syncScrollEnabled(),
    );
    lines.status_line = lines.owned_status_line.?;
    return lines;
}

pub fn renderMinimizedToolbarLine(allocator: std.mem.Allocator, wm: *workspace.WorkspaceManager) ![]u8 {
    var list = std.ArrayListUnmanaged(u8){};
    errdefer list.deinit(allocator);

    try list.appendSlice(allocator, "min: ");
    const tab = wm.activeTab() catch return list.toOwnedSlice(allocator);
    for (tab.windows.items) |w| {
        if (!w.minimized) continue;
        try list.appendSlice(allocator, "[");
        try list.writer(allocator).print("{d}:{s}", .{ w.id, w.title });
        try list.appendSlice(allocator, "] ");
    }
    return list.toOwnedSlice(allocator);
}

pub fn minimizedToolbarHitAt(
    wm: *workspace.WorkspaceManager,
    content: layout.Rect,
    px: u16,
    py: u16,
) ?struct { window_id: u32, window_index: usize } {
    if (py != content.y + content.height) return null;
    const tab = wm.activeTab() catch return null;

    var x: u16 = 5;
    for (tab.windows.items, 0..) |w, i| {
        if (!w.minimized) continue;

        var id_buf: [16]u8 = undefined;
        const id_txt = std.fmt.bufPrint(&id_buf, "{d}", .{w.id}) catch continue;
        const seg_w: u16 = @intCast(1 + id_txt.len + 1 + w.title.len + 2);
        const start = x;
        const end = x + seg_w;
        if (px >= start and px < end) return .{ .window_id = w.id, .window_index = i };
        x = end;
    }
    return null;
}
