const std = @import("std");
const layout = @import("layout.zig");
const window_mod = @import("window.zig");

pub const Tab = struct {
    name: []u8,
    windows: std.ArrayListUnmanaged(window_mod.Window) = .{},
    focused_index: ?usize = null,
    layout_type: layout.LayoutType = .vertical_stack,
    master_count: u16 = 1,
    master_ratio_permille: u16 = 600,
    gap: u16 = 0,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) !Tab {
        return .{ .name = try allocator.dupe(u8, name) };
    }

    pub fn deinit(self: *Tab, allocator: std.mem.Allocator) void {
        for (self.windows.items) |*w| w.deinit(allocator);
        self.windows.deinit(allocator);
        allocator.free(self.name);
        self.* = undefined;
    }
};

pub const WorkspaceManager = struct {
    allocator: std.mem.Allocator,
    layout_engine: layout.LayoutEngine,
    tabs: std.ArrayListUnmanaged(Tab) = .{},
    active_tab_index: ?usize = null,
    next_window_id: u32 = 1,

    pub fn init(allocator: std.mem.Allocator, layout_engine: layout.LayoutEngine) WorkspaceManager {
        return .{
            .allocator = allocator,
            .layout_engine = layout_engine,
        };
    }

    pub fn deinit(self: *WorkspaceManager) void {
        for (self.tabs.items) |*tab| tab.deinit(self.allocator);
        self.tabs.deinit(self.allocator);
        self.layout_engine.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn createTab(self: *WorkspaceManager, name: []const u8) !usize {
        var tab = try Tab.init(self.allocator, name);
        errdefer tab.deinit(self.allocator);

        try self.tabs.append(self.allocator, tab);
        const idx = self.tabs.items.len - 1;
        if (self.active_tab_index == null) self.active_tab_index = idx;
        return idx;
    }

    pub fn switchTab(self: *WorkspaceManager, index: usize) !void {
        if (index >= self.tabs.items.len) return error.InvalidTabIndex;
        self.active_tab_index = index;
    }

    pub fn activeTab(self: *WorkspaceManager) !*Tab {
        const idx = self.active_tab_index orelse return error.NoActiveTab;
        return &self.tabs.items[idx];
    }

    pub fn tabCount(self: *const WorkspaceManager) usize {
        return self.tabs.items.len;
    }

    pub fn activeTabIndex(self: *const WorkspaceManager) ?usize {
        return self.active_tab_index;
    }

    pub fn activeWindowCount(self: *WorkspaceManager) !usize {
        const tab = try self.activeTab();
        return tab.windows.items.len;
    }

    pub fn addWindowToActive(self: *WorkspaceManager, title: []const u8) !u32 {
        var tab = try self.activeTab();
        const id = self.next_window_id;
        self.next_window_id += 1;

        const w = try window_mod.Window.init(self.allocator, id, title);
        try tab.windows.append(self.allocator, w);
        if (tab.focused_index == null) tab.focused_index = 0;
        return id;
    }

    pub fn computeActiveLayout(self: *WorkspaceManager, screen: layout.Rect) ![]layout.Rect {
        const tab = try self.activeTab();
        const window_count: u16 = @intCast(tab.windows.items.len);
        return self.layout_engine.compute(self.allocator, .{
            .layout = tab.layout_type,
            .screen = screen,
            .window_count = window_count,
            .master_count = tab.master_count,
            .master_ratio_permille = tab.master_ratio_permille,
            .gap = tab.gap,
        });
    }

    pub fn moveFocusedWindowToTab(self: *WorkspaceManager, destination_index: usize) !void {
        if (destination_index >= self.tabs.items.len) return error.InvalidTabIndex;

        const src_index = self.active_tab_index orelse return error.NoActiveTab;
        if (src_index == destination_index) return;

        var src = &self.tabs.items[src_index];
        const focus = src.focused_index orelse return error.NoFocusedWindow;
        if (focus >= src.windows.items.len) return error.NoFocusedWindow;

        const moved = src.windows.orderedRemove(focus);
        errdefer {
            src.windows.insert(self.allocator, focus, moved) catch {};
        }

        var dst = &self.tabs.items[destination_index];
        try dst.windows.append(self.allocator, moved);

        if (dst.focused_index == null) dst.focused_index = dst.windows.items.len - 1;

        if (src.windows.items.len == 0) {
            src.focused_index = null;
        } else if (focus >= src.windows.items.len) {
            src.focused_index = src.windows.items.len - 1;
        }
    }

    pub fn focusedWindowIdActive(self: *WorkspaceManager) !u32 {
        const tab = try self.activeTab();
        const focus = tab.focused_index orelse return error.NoFocusedWindow;
        if (focus >= tab.windows.items.len) return error.NoFocusedWindow;
        return tab.windows.items[focus].id;
    }

    pub fn focusNextWindowActive(self: *WorkspaceManager) !void {
        const tab = try self.activeTab();
        if (tab.windows.items.len == 0) return error.NoFocusedWindow;
        const current = tab.focused_index orelse 0;
        tab.focused_index = (current + 1) % tab.windows.items.len;
    }

    pub fn focusPrevWindowActive(self: *WorkspaceManager) !void {
        const tab = try self.activeTab();
        if (tab.windows.items.len == 0) return error.NoFocusedWindow;
        const current = tab.focused_index orelse 0;
        tab.focused_index = if (current == 0) tab.windows.items.len - 1 else current - 1;
    }

    pub fn closeFocusedWindowActive(self: *WorkspaceManager) !u32 {
        const tab = try self.activeTab();
        const focus = tab.focused_index orelse return error.NoFocusedWindow;
        if (focus >= tab.windows.items.len) return error.NoFocusedWindow;

        var w = tab.windows.orderedRemove(focus);
        const id = w.id;
        w.deinit(self.allocator);

        if (tab.windows.items.len == 0) {
            tab.focused_index = null;
        } else if (focus >= tab.windows.items.len) {
            tab.focused_index = tab.windows.items.len - 1;
        } else {
            tab.focused_index = focus;
        }

        return id;
    }
};

test "workspace manager supports tabs and window movement" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var wm = WorkspaceManager.init(testing.allocator, engine);
    defer wm.deinit();

    const a = try wm.createTab("dev");
    const b = try wm.createTab("ops");
    try testing.expectEqual(@as(usize, 0), a);
    try testing.expectEqual(@as(usize, 1), b);

    _ = try wm.addWindowToActive("shell-1");
    _ = try wm.addWindowToActive("shell-2");

    const before = try wm.computeActiveLayout(.{ .x = 0, .y = 0, .width = 80, .height = 24 });
    defer testing.allocator.free(before);
    try testing.expectEqual(@as(usize, 2), before.len);

    try wm.moveFocusedWindowToTab(1);
    try wm.switchTab(1);

    const ops_tab = try wm.activeTab();
    try testing.expectEqual(@as(usize, 1), ops_tab.windows.items.len);
    try testing.expectEqualStrings("shell-1", ops_tab.windows.items[0].title);
}
