const std = @import("std");
const workspace_mod = @import("workspace.zig");

pub const RenderedStatus = struct {
    tab_bar: []u8,
    status_bar: []u8,

    pub fn deinit(self: *RenderedStatus, allocator: std.mem.Allocator) void {
        allocator.free(self.tab_bar);
        allocator.free(self.status_bar);
        self.* = undefined;
    }
};

pub fn render(allocator: std.mem.Allocator, wm: *workspace_mod.WorkspaceManager) !RenderedStatus {
    return .{
        .tab_bar = try renderTabBar(allocator, wm),
        .status_bar = try renderStatusBarWithScroll(allocator, wm, 0),
    };
}

pub fn renderTabBar(allocator: std.mem.Allocator, wm: *workspace_mod.WorkspaceManager) ![]u8 {
    var list = std.ArrayList(u8).empty;
    errdefer list.deinit(allocator);
    const writer = list.writer(allocator);
    const active_idx = wm.activeTabIndex() orelse 0;

    for (wm.tabs.items, 0..) |tab, i| {
        const marker: u8 = if (i == active_idx) '*' else ' ';
        try writer.print("[{c}{d}:{s}({d})]", .{
            marker,
            i + 1,
            tab.name,
            tab.windows.items.len,
        });
        if (i + 1 < wm.tabs.items.len) try writer.writeByte(' ');
    }

    return try list.toOwnedSlice(allocator);
}

pub fn renderStatusBar(allocator: std.mem.Allocator, wm: *workspace_mod.WorkspaceManager) ![]u8 {
    return renderStatusBarWithScroll(allocator, wm, 0);
}

pub fn renderStatusBarWithScroll(
    allocator: std.mem.Allocator,
    wm: *workspace_mod.WorkspaceManager,
    scroll_offset: usize,
) ![]u8 {
    return renderStatusBarWithScrollAndSync(allocator, wm, scroll_offset, false);
}

pub fn renderStatusBarWithScrollAndSync(
    allocator: std.mem.Allocator,
    wm: *workspace_mod.WorkspaceManager,
    scroll_offset: usize,
    sync_scroll_enabled: bool,
) ![]u8 {
    var list = std.ArrayList(u8).empty;
    errdefer list.deinit(allocator);
    const writer = list.writer(allocator);

    const tab = try wm.activeTab();
    const layout_type = try wm.activeLayoutType();
    const focus_title = blk: {
        const focus = tab.focused_index orelse break :blk "(none)";
        if (focus >= tab.windows.items.len) break :blk "(none)";
        break :blk tab.windows.items[focus].title;
    };

    try writer.print("layout={s} windows={d} focused={s}", .{
        @tagName(layout_type),
        tab.windows.items.len,
        focus_title,
    });
    try writer.print(" scroll=+{d}", .{scroll_offset});
    try writer.print(" sync_scroll={s}", .{if (sync_scroll_enabled) "on" else "off"});

    return try list.toOwnedSlice(allocator);
}

test "status renders tab and status lines" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();
    var wm = workspace_mod.WorkspaceManager.init(testing.allocator, engine);
    defer wm.deinit();

    _ = try wm.createTab("dev");
    _ = try wm.createTab("ops");
    _ = try wm.addWindowToActive("shell-1");
    _ = try wm.addWindowToActive("shell-2");

    const tab_bar = try renderTabBar(testing.allocator, &wm);
    defer testing.allocator.free(tab_bar);
    try testing.expect(std.mem.indexOf(u8, tab_bar, "*1:dev(2)") != null);
    try testing.expect(std.mem.indexOf(u8, tab_bar, " 2:ops(0)") != null);

    const status_bar = try renderStatusBar(testing.allocator, &wm);
    defer testing.allocator.free(status_bar);
    try testing.expect(std.mem.indexOf(u8, status_bar, "layout=vertical_stack") != null);
    try testing.expect(std.mem.indexOf(u8, status_bar, "focused=shell-1") != null);
    try testing.expect(std.mem.indexOf(u8, status_bar, "scroll=+0") != null);
    try testing.expect(std.mem.indexOf(u8, status_bar, "sync_scroll=off") != null);
}
