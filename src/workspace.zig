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
        const total_count = tab.windows.items.len;
        var rects = try self.allocator.alloc(layout.Rect, total_count);
        @memset(rects, .{ .x = screen.x, .y = screen.y, .width = 0, .height = 0 });

        var visible_indices = std.ArrayListUnmanaged(usize){};
        defer visible_indices.deinit(self.allocator);
        for (tab.windows.items, 0..) |w, i| {
            if (!w.minimized) try visible_indices.append(self.allocator, i);
        }
        if (visible_indices.items.len == 0) return rects;

        var visible_window_ids = try self.allocator.alloc(u32, visible_indices.items.len);
        defer self.allocator.free(visible_window_ids);
        for (visible_indices.items, 0..) |idx, vis_i| {
            visible_window_ids[vis_i] = tab.windows.items[idx].id;
        }

        const focused_index_visible: u16 = blk: {
            const focus = tab.focused_index orelse break :blk 0;
            if (focus >= tab.windows.items.len or tab.windows.items[focus].minimized) break :blk 0;
            var pos: u16 = 0;
            for (visible_indices.items) |idx| {
                if (idx == focus) break :blk pos;
                pos += 1;
            }
            break :blk 0;
        };

        const visible_count_u16: u16 = @intCast(visible_indices.items.len);
        const visible_rects = try self.layout_engine.compute(self.allocator, .{
            .layout = tab.layout_type,
            .screen = screen,
            .window_count = visible_count_u16,
            .window_ids = visible_window_ids,
            .focused_index = focused_index_visible,
            .master_count = tab.master_count,
            .master_ratio_permille = tab.master_ratio_permille,
            .gap = tab.gap,
        });
        defer self.allocator.free(visible_rects);

        for (visible_indices.items, 0..) |idx, vis_i| {
            rects[idx] = visible_rects[vis_i];
        }
        return rects;
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

    pub fn focusedWindowIndexActive(self: *WorkspaceManager) !usize {
        const tab = try self.activeTab();
        const focus = tab.focused_index orelse return error.NoFocusedWindow;
        if (focus >= tab.windows.items.len) return error.NoFocusedWindow;
        return focus;
    }

    pub fn setFocusedWindowIndexActive(self: *WorkspaceManager, index: usize) !void {
        const tab = try self.activeTab();
        if (index >= tab.windows.items.len) return error.InvalidWindowIndex;
        tab.focused_index = index;
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

    pub fn zoomFocusedToMasterActive(self: *WorkspaceManager) !bool {
        const tab = try self.activeTab();
        const focus = tab.focused_index orelse return error.NoFocusedWindow;
        if (focus >= tab.windows.items.len) return error.NoFocusedWindow;
        if (focus == 0) return false;

        std.mem.swap(window_mod.Window, &tab.windows.items[0], &tab.windows.items[focus]);
        tab.focused_index = 0;
        return true;
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

    pub fn closeWindowById(self: *WorkspaceManager, window_id: u32) !bool {
        for (self.tabs.items) |*tab| {
            var i: usize = 0;
            while (i < tab.windows.items.len) : (i += 1) {
                if (tab.windows.items[i].id != window_id) continue;

                var w = tab.windows.orderedRemove(i);
                w.deinit(self.allocator);

                if (tab.windows.items.len == 0) {
                    tab.focused_index = null;
                } else if (tab.focused_index) |focus| {
                    if (focus == i and i >= tab.windows.items.len) {
                        tab.focused_index = tab.windows.items.len - 1;
                    } else if (focus > i) {
                        tab.focused_index = focus - 1;
                    }
                }
                return true;
            }
        }
        return false;
    }

    pub fn activeLayoutType(self: *WorkspaceManager) !layout.LayoutType {
        const tab = try self.activeTab();
        return tab.layout_type;
    }

    pub fn setActiveLayout(self: *WorkspaceManager, layout_type: layout.LayoutType) !void {
        const tab = try self.activeTab();
        tab.layout_type = layout_type;
    }

    pub fn setActiveLayoutDefaults(
        self: *WorkspaceManager,
        layout_type: layout.LayoutType,
        master_count: u16,
        master_ratio_permille: u16,
        gap: u16,
    ) !void {
        if (master_ratio_permille > 1000) return error.InvalidMasterRatio;
        const tab = try self.activeTab();
        tab.layout_type = layout_type;
        tab.master_count = master_count;
        tab.master_ratio_permille = master_ratio_permille;
        tab.gap = gap;
    }

    pub fn cycleActiveLayout(self: *WorkspaceManager) !layout.LayoutType {
        const tab = try self.activeTab();
        tab.layout_type = switch (tab.layout_type) {
            .vertical_stack => .horizontal_stack,
            .horizontal_stack => .grid,
            .grid => .paperwm,
            .paperwm => .fullscreen,
            .fullscreen => .vertical_stack,
        };
        return tab.layout_type;
    }

    pub fn activeMasterRatioPermille(self: *WorkspaceManager) !u16 {
        const tab = try self.activeTab();
        return tab.master_ratio_permille;
    }

    pub fn setActiveMasterRatioPermille(self: *WorkspaceManager, ratio: u16) !void {
        if (ratio > 1000) return error.InvalidMasterRatio;
        const tab = try self.activeTab();
        tab.master_ratio_permille = ratio;
    }

    pub fn activeMasterCount(self: *WorkspaceManager) !u16 {
        const tab = try self.activeTab();
        return tab.master_count;
    }

    pub fn setActiveMasterCount(self: *WorkspaceManager, count: u16) !void {
        const tab = try self.activeTab();
        tab.master_count = if (count == 0) 1 else count;
    }

    pub fn minimizeFocusedWindowActive(self: *WorkspaceManager) !u32 {
        const tab = try self.activeTab();
        const focus = tab.focused_index orelse return error.NoFocusedWindow;
        if (focus >= tab.windows.items.len) return error.NoFocusedWindow;

        tab.windows.items[focus].minimized = true;
        const id = tab.windows.items[focus].id;

        var next_focus: ?usize = null;
        var i = focus + 1;
        while (i < tab.windows.items.len) : (i += 1) {
            if (!tab.windows.items[i].minimized) {
                next_focus = i;
                break;
            }
        }
        if (next_focus == null and focus > 0) {
            i = focus;
            while (i > 0) {
                i -= 1;
                if (!tab.windows.items[i].minimized) {
                    next_focus = i;
                    break;
                }
            }
        }
        tab.focused_index = next_focus;
        return id;
    }

    pub fn restoreAllMinimizedActive(self: *WorkspaceManager) !usize {
        const tab = try self.activeTab();
        var restored: usize = 0;
        for (tab.windows.items) |*w| {
            if (!w.minimized) continue;
            w.minimized = false;
            restored += 1;
        }
        if (tab.focused_index == null and tab.windows.items.len > 0) {
            tab.focused_index = 0;
        }
        return restored;
    }

    pub fn restoreWindowByIdActive(self: *WorkspaceManager, window_id: u32) !bool {
        const tab = try self.activeTab();
        for (tab.windows.items, 0..) |*w, i| {
            if (w.id != window_id) continue;
            if (!w.minimized) return false;
            w.minimized = false;
            if (tab.focused_index == null) tab.focused_index = i;
            return true;
        }
        return false;
    }

    pub fn moveFocusedWindowToIndexActive(self: *WorkspaceManager, dst_index: usize) !void {
        const tab = try self.activeTab();
        const focus = tab.focused_index orelse return error.NoFocusedWindow;
        if (focus >= tab.windows.items.len) return error.NoFocusedWindow;
        if (tab.windows.items.len == 0) return error.NoFocusedWindow;

        const clamped_dst = @min(dst_index, tab.windows.items.len - 1);
        if (focus == clamped_dst) return;

        const moved = tab.windows.orderedRemove(focus);
        try tab.windows.insert(self.allocator, clamped_dst, moved);
        tab.focused_index = clamped_dst;
    }

    pub fn moveWindowByIdToIndexActive(self: *WorkspaceManager, window_id: u32, dst_index: usize) !bool {
        const tab = try self.activeTab();
        if (tab.windows.items.len == 0) return false;

        var src_index_opt: ?usize = null;
        for (tab.windows.items, 0..) |w, i| {
            if (w.id == window_id) {
                src_index_opt = i;
                break;
            }
        }
        const src_index = src_index_opt orelse return false;
        const clamped_dst = @min(dst_index, tab.windows.items.len - 1);
        if (src_index == clamped_dst) {
            tab.focused_index = clamped_dst;
            return true;
        }

        const moved = tab.windows.orderedRemove(src_index);
        try tab.windows.insert(self.allocator, clamped_dst, moved);
        tab.focused_index = clamped_dst;
        return true;
    }

    pub fn closeActiveTab(self: *WorkspaceManager, allocator: std.mem.Allocator) ![]u32 {
        const idx = self.active_tab_index orelse return error.NoActiveTab;
        if (self.tabs.items.len <= 1) return error.CannotCloseLastTab;

        const tab = &self.tabs.items[idx];
        var removed_ids = try allocator.alloc(u32, tab.windows.items.len);
        for (tab.windows.items, 0..) |w, i| {
            removed_ids[i] = w.id;
        }

        var removed = self.tabs.orderedRemove(idx);
        removed.deinit(self.allocator);

        if (idx >= self.tabs.items.len) {
            self.active_tab_index = self.tabs.items.len - 1;
        } else {
            self.active_tab_index = idx;
        }

        return removed_ids;
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

test "workspace manager can set focused window by index" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var wm = WorkspaceManager.init(testing.allocator, engine);
    defer wm.deinit();

    _ = try wm.createTab("dev");
    _ = try wm.addWindowToActive("a");
    _ = try wm.addWindowToActive("b");

    try wm.setFocusedWindowIndexActive(1);
    try testing.expectEqual(@as(usize, 1), try wm.focusedWindowIndexActive());
}

test "workspace manager can set active master ratio" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var wm = WorkspaceManager.init(testing.allocator, engine);
    defer wm.deinit();

    _ = try wm.createTab("dev");
    _ = try wm.addWindowToActive("a");
    _ = try wm.addWindowToActive("b");

    try wm.setActiveMasterRatioPermille(700);
    try testing.expectEqual(@as(u16, 700), try wm.activeMasterRatioPermille());
}

test "workspace manager zoom moves focused window to master slot" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var wm = WorkspaceManager.init(testing.allocator, engine);
    defer wm.deinit();

    _ = try wm.createTab("dev");
    const a = try wm.addWindowToActive("a");
    _ = try wm.addWindowToActive("b");
    const c = try wm.addWindowToActive("c");

    try wm.setFocusedWindowIndexActive(2);
    const changed = try wm.zoomFocusedToMasterActive();
    try testing.expect(changed);
    try testing.expectEqual(@as(usize, 0), try wm.focusedWindowIndexActive());

    const tab = try wm.activeTab();
    try testing.expectEqual(c, tab.windows.items[0].id);
    try testing.expectEqual(a, tab.windows.items[2].id);

    const unchanged = try wm.zoomFocusedToMasterActive();
    try testing.expect(!unchanged);
}

test "workspace manager cycles active layout order" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var wm = WorkspaceManager.init(testing.allocator, engine);
    defer wm.deinit();

    _ = try wm.createTab("dev");
    try testing.expectEqual(layout.LayoutType.vertical_stack, try wm.activeLayoutType());
    try testing.expectEqual(layout.LayoutType.horizontal_stack, try wm.cycleActiveLayout());
    try testing.expectEqual(layout.LayoutType.grid, try wm.cycleActiveLayout());
    try testing.expectEqual(layout.LayoutType.paperwm, try wm.cycleActiveLayout());
    try testing.expectEqual(layout.LayoutType.fullscreen, try wm.cycleActiveLayout());
    try testing.expectEqual(layout.LayoutType.vertical_stack, try wm.cycleActiveLayout());
}

test "workspace manager closes active tab and keeps another active" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var wm = WorkspaceManager.init(testing.allocator, engine);
    defer wm.deinit();

    _ = try wm.createTab("dev");
    _ = try wm.createTab("ops");
    _ = try wm.addWindowToActive("a");

    const removed = try wm.closeActiveTab(testing.allocator);
    defer testing.allocator.free(removed);

    try testing.expectEqual(@as(usize, 1), removed.len);
    try testing.expectEqual(@as(usize, 1), wm.tabCount());
    try testing.expectEqual(@as(usize, 0), wm.activeTabIndex().?);
}

test "workspace manager minimizes focused window and can restore all" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var wm = WorkspaceManager.init(testing.allocator, engine);
    defer wm.deinit();

    _ = try wm.createTab("dev");
    const a = try wm.addWindowToActive("a");
    _ = try wm.addWindowToActive("b");

    const min_id = try wm.minimizeFocusedWindowActive();
    try testing.expectEqual(a, min_id);
    try testing.expectEqual(@as(usize, 1), try wm.focusedWindowIndexActive());

    const restored = try wm.restoreAllMinimizedActive();
    try testing.expectEqual(@as(usize, 1), restored);
}

test "workspace manager moves focused window to target index" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var wm = WorkspaceManager.init(testing.allocator, engine);
    defer wm.deinit();

    _ = try wm.createTab("dev");
    const a = try wm.addWindowToActive("a");
    const b = try wm.addWindowToActive("b");
    _ = b;
    const c = try wm.addWindowToActive("c");
    _ = c;

    try wm.setFocusedWindowIndexActive(0);
    try wm.moveFocusedWindowToIndexActive(2);
    try testing.expectEqual(@as(usize, 2), try wm.focusedWindowIndexActive());
    const tab = try wm.activeTab();
    try testing.expectEqual(a, tab.windows.items[2].id);
}

test "workspace manager restores minimized window by id" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var wm = WorkspaceManager.init(testing.allocator, engine);
    defer wm.deinit();

    _ = try wm.createTab("dev");
    const a = try wm.addWindowToActive("a");
    _ = try wm.addWindowToActive("b");

    _ = try wm.minimizeFocusedWindowActive();
    try testing.expect(try wm.restoreWindowByIdActive(a));
    try testing.expect(!(try wm.restoreWindowByIdActive(999999)));
}
