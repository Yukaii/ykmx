const std = @import("std");
const layout = @import("layout.zig");
const workspace = @import("workspace.zig");
const pty_mod = @import("pty.zig");
const input_mod = @import("input.zig");
const signal_mod = @import("signal.zig");

pub const Multiplexer = struct {
    allocator: std.mem.Allocator,
    workspace_mgr: workspace.WorkspaceManager,
    ptys: std.AutoHashMapUnmanaged(u32, pty_mod.Pty) = .{},
    stdout_buffers: std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(u8)) = .{},
    dirty_windows: std.AutoHashMapUnmanaged(u32, void) = .{},
    input_router: input_mod.Router = .{},
    detach_requested: bool = false,
    last_mouse_event: ?input_mod.MouseEvent = null,

    pub const TickResult = struct {
        reads: usize,
        resized: usize,
        redraw: bool,
        should_shutdown: bool,
        detach_requested: bool,
    };

    pub fn init(allocator: std.mem.Allocator, layout_engine: layout.LayoutEngine) Multiplexer {
        return .{
            .allocator = allocator,
            .workspace_mgr = workspace.WorkspaceManager.init(allocator, layout_engine),
        };
    }

    pub fn deinit(self: *Multiplexer) void {
        var it_ptys = self.ptys.iterator();
        while (it_ptys.next()) |entry| {
            var p = entry.value_ptr.*;
            p.deinit();
        }
        self.ptys.deinit(self.allocator);

        var it_buf = self.stdout_buffers.iterator();
        while (it_buf.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.stdout_buffers.deinit(self.allocator);
        self.dirty_windows.deinit(self.allocator);

        self.workspace_mgr.deinit();
        self.* = undefined;
    }

    pub fn createTab(self: *Multiplexer, name: []const u8) !usize {
        return self.workspace_mgr.createTab(name);
    }

    pub fn switchTab(self: *Multiplexer, index: usize) !void {
        try self.workspace_mgr.switchTab(index);
    }

    pub fn createShellWindow(self: *Multiplexer, title: []const u8) !u32 {
        const id = try self.workspace_mgr.addWindowToActive(title);
        var p = try pty_mod.Pty.spawnShell(self.allocator);
        errdefer p.deinit();

        try self.ptys.put(self.allocator, id, p);
        try self.stdout_buffers.put(self.allocator, id, .{});
        return id;
    }

    pub fn createCommandWindow(self: *Multiplexer, title: []const u8, argv: []const []const u8) !u32 {
        const id = try self.workspace_mgr.addWindowToActive(title);
        var p = try pty_mod.Pty.spawnCommand(self.allocator, argv);
        errdefer p.deinit();

        try self.ptys.put(self.allocator, id, p);
        try self.stdout_buffers.put(self.allocator, id, .{});
        return id;
    }

    pub fn computeActiveLayout(self: *Multiplexer, screen: layout.Rect) ![]layout.Rect {
        return self.workspace_mgr.computeActiveLayout(screen);
    }

    pub fn sendInputToFocused(self: *Multiplexer, bytes: []const u8) !void {
        const focused_id = try self.workspace_mgr.focusedWindowIdActive();
        const p = self.ptys.getPtr(focused_id) orelse return error.UnknownWindow;
        try p.write(bytes);
    }

    pub fn handleInputBytes(self: *Multiplexer, bytes: []const u8) !void {
        for (bytes) |b| {
            const ev = self.input_router.feedByte(b);
            switch (ev) {
                .forward => |c| {
                    var tmp = [_]u8{c};
                    try self.sendInputToFocused(&tmp);
                },
                .forward_sequence => |seq| {
                    try self.sendInputToFocused(seq.slice());
                    if (seq.mouse) |mouse| self.last_mouse_event = mouse;
                },
                .command => |cmd| switch (cmd) {
                    .create_window => {
                        _ = try self.createShellWindow("shell");
                    },
                    .close_window => {
                        _ = try self.closeFocusedWindow();
                    },
                    .next_tab => {
                        const n = self.workspace_mgr.tabCount();
                        if (n > 0) {
                            const current = self.workspace_mgr.activeTabIndex() orelse 0;
                            try self.switchTab((current + 1) % n);
                        }
                    },
                    .prev_tab => {
                        const n = self.workspace_mgr.tabCount();
                        if (n > 0) {
                            const current = self.workspace_mgr.activeTabIndex() orelse 0;
                            const prev = if (current == 0) n - 1 else current - 1;
                            try self.switchTab(prev);
                        }
                    },
                    .next_window => try self.workspace_mgr.focusNextWindowActive(),
                    .prev_window => try self.workspace_mgr.focusPrevWindowActive(),
                    .detach => {
                        self.detach_requested = true;
                    },
                },
                .noop => {},
            }
        }
    }

    pub fn resizeActiveWindowsToLayout(self: *Multiplexer, screen: layout.Rect) !usize {
        const rects = try self.computeActiveLayout(screen);
        defer self.allocator.free(rects);

        const tab = try self.workspace_mgr.activeTab();
        var resized: usize = 0;

        const n = @min(tab.windows.items.len, rects.len);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const w = tab.windows.items[i];
            const p = self.ptys.getPtr(w.id) orelse continue;
            const r = rects[i];
            try p.resize(r.height, r.width);
            try self.markWindowDirty(w.id);
            resized += 1;
        }

        return resized;
    }

    pub fn pollOnce(self: *Multiplexer, timeout_ms: i32) !usize {
        var pollfds: std.ArrayListUnmanaged(posixPollFd()) = .{};
        defer pollfds.deinit(self.allocator);

        var ids: std.ArrayListUnmanaged(u32) = .{};
        defer ids.deinit(self.allocator);

        var it = self.ptys.iterator();
        while (it.next()) |entry| {
            const w_id = entry.key_ptr.*;
            const p = entry.value_ptr;
            const out = p.stdoutFile() orelse continue;

            try ids.append(self.allocator, w_id);
            try pollfds.append(self.allocator, .{
                .fd = out.handle,
                .events = std.posix.POLL.IN,
                .revents = 0,
            });
        }

        if (pollfds.items.len == 0) return 0;

        const ready = try std.posix.poll(pollfds.items, timeout_ms);
        if (ready == 0) return 0;

        var reads: usize = 0;
        var tmp: [4096]u8 = undefined;

        for (pollfds.items, 0..) |fd, i| {
            if ((fd.revents & std.posix.POLL.IN) == 0 and (fd.revents & std.posix.POLL.HUP) == 0) continue;

            const w_id = ids.items[i];
            const p = self.ptys.getPtr(w_id) orelse continue;
            const n = try p.readStdout(&tmp);
            if (n == 0) continue;

            const out_buf = self.stdout_buffers.getPtr(w_id) orelse return error.MissingOutputBuffer;
            try out_buf.appendSlice(self.allocator, tmp[0..n]);
            try self.markWindowDirty(w_id);
            reads += 1;
        }

        return reads;
    }

    pub fn windowOutput(self: *Multiplexer, window_id: u32) ![]const u8 {
        const list = self.stdout_buffers.getPtr(window_id) orelse return error.UnknownWindow;
        return list.items;
    }

    pub fn clearWindowOutput(self: *Multiplexer, window_id: u32) !void {
        const list = self.stdout_buffers.getPtr(window_id) orelse return error.UnknownWindow;
        list.clearRetainingCapacity();
    }

    pub fn focusedWindowId(self: *Multiplexer) !u32 {
        return self.workspace_mgr.focusedWindowIdActive();
    }

    pub fn dirtyWindowIds(self: *Multiplexer, allocator: std.mem.Allocator) ![]u32 {
        var ids = try allocator.alloc(u32, self.dirty_windows.count());
        errdefer allocator.free(ids);

        var i: usize = 0;
        var it = self.dirty_windows.iterator();
        while (it.next()) |entry| : (i += 1) ids[i] = entry.key_ptr.*;
        return ids;
    }

    pub fn clearDirtyWindow(self: *Multiplexer, window_id: u32) void {
        _ = self.dirty_windows.swapRemove(window_id);
    }

    pub fn clearAllDirty(self: *Multiplexer) void {
        self.dirty_windows.clearRetainingCapacity();
    }

    pub fn consumeDetachRequested(self: *Multiplexer) bool {
        const value = self.detach_requested;
        self.detach_requested = false;
        return value;
    }

    pub fn consumeLastMouseEvent(self: *Multiplexer) ?input_mod.MouseEvent {
        const value = self.last_mouse_event;
        self.last_mouse_event = null;
        return value;
    }

    pub fn tick(
        self: *Multiplexer,
        timeout_ms: i32,
        screen: layout.Rect,
        signals: signal_mod.Snapshot,
    ) !TickResult {
        const detach_requested = self.consumeDetachRequested();

        if (signals.sighup or signals.sigterm) {
            try self.gracefulShutdown();
            return .{
                .reads = 0,
                .resized = 0,
                .redraw = false,
                .should_shutdown = true,
                .detach_requested = detach_requested,
            };
        }

        var resized: usize = 0;
        var redraw = false;
        if (signals.sigwinch) {
            resized = try self.resizeActiveWindowsToLayout(screen);
            redraw = true;
        }

        const reads = try self.pollOnce(timeout_ms);
        if (reads > 0) redraw = true;

        return .{
            .reads = reads,
            .resized = resized,
            .redraw = redraw,
            .should_shutdown = false,
            .detach_requested = detach_requested,
        };
    }

    pub fn gracefulShutdown(self: *Multiplexer) !void {
        var it = self.ptys.iterator();
        while (it.next()) |entry| {
            var p = entry.value_ptr.*;
            _ = p.terminate() catch {};
            _ = p.wait() catch {};
            p.deinit();
        }
        self.ptys.clearRetainingCapacity();
    }

    pub fn closeFocusedWindow(self: *Multiplexer) !u32 {
        const id = try self.workspace_mgr.closeFocusedWindowActive();
        if (self.ptys.getPtr(id)) |p| p.deinit();
        _ = self.ptys.fetchRemove(id);

        if (self.stdout_buffers.getPtr(id)) |list| list.deinit(self.allocator);
        _ = self.stdout_buffers.fetchRemove(id);
        _ = self.dirty_windows.fetchRemove(id);

        return id;
    }

    fn markWindowDirty(self: *Multiplexer, window_id: u32) !void {
        try self.dirty_windows.put(self.allocator, window_id, {});
    }

    fn posixPollFd() type {
        return std.posix.pollfd;
    }
};

test "multiplexer routes command output to the owning window" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("dev");
    const win_id = try mux.createCommandWindow("echo", &.{ "/bin/sh", "-c", "printf 'mux-ok\\n'" });

    var tries: usize = 0;
    while (tries < 20) : (tries += 1) {
        _ = try mux.pollOnce(50);
        const out = try mux.windowOutput(win_id);
        if (std.mem.indexOf(u8, out, "mux-ok") != null) break;
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }

    const out = try mux.windowOutput(win_id);
    try testing.expect(std.mem.indexOf(u8, out, "mux-ok") != null);
}

test "multiplexer propagates active layout size to ptys" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("dev");
    _ = try mux.createCommandWindow("a", &.{ "/bin/sh", "-c", "sleep 0.2" });
    _ = try mux.createCommandWindow("b", &.{ "/bin/sh", "-c", "sleep 0.2" });

    const resized = try mux.resizeActiveWindowsToLayout(.{ .x = 0, .y = 0, .width = 80, .height = 24 });
    try testing.expectEqual(@as(usize, 2), resized);
}

test "multiplexer forwards input to focused window pty" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("dev");
    const win_id = try mux.createCommandWindow("cat", &.{"/bin/cat"});

    try mux.sendInputToFocused("ping\n");

    var tries: usize = 0;
    while (tries < 40) : (tries += 1) {
        _ = try mux.pollOnce(30);
        const out = try mux.windowOutput(win_id);
        if (std.mem.indexOf(u8, out, "ping") != null) break;
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }

    const out = try mux.windowOutput(win_id);
    try testing.expect(std.mem.indexOf(u8, out, "ping") != null);
}

test "multiplexer handles prefix create-window command" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("dev");
    const before = try mux.workspace_mgr.activeWindowCount();
    try mux.handleInputBytes(&.{ 0x07, 'c' });
    const after = try mux.workspace_mgr.activeWindowCount();

    try testing.expectEqual(before + 1, after);
}

test "multiplexer tick handles sigwinch and reports redraw" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("dev");
    _ = try mux.createCommandWindow("a", &.{ "/bin/sh", "-c", "sleep 0.2" });

    const result = try mux.tick(0, .{ .x = 0, .y = 0, .width = 80, .height = 24 }, .{
        .sigwinch = true,
        .sighup = false,
        .sigterm = false,
    });

    try testing.expectEqual(@as(usize, 1), result.resized);
    try testing.expect(result.redraw);
    try testing.expect(!result.should_shutdown);
}

test "multiplexer tick handles sigterm shutdown" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("dev");
    _ = try mux.createCommandWindow("a", &.{ "/bin/sh", "-c", "sleep 0.2" });

    const result = try mux.tick(0, .{ .x = 0, .y = 0, .width = 80, .height = 24 }, .{
        .sigwinch = false,
        .sighup = false,
        .sigterm = true,
    });

    try testing.expect(result.should_shutdown);
    try testing.expectEqual(@as(usize, 0), mux.ptys.count());
    try testing.expect(!result.detach_requested);
}

test "multiplexer close focused window command cleans up maps" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("dev");
    _ = try mux.createCommandWindow("a", &.{ "/bin/sh", "-c", "sleep 0.2" });
    _ = try mux.createCommandWindow("b", &.{ "/bin/sh", "-c", "sleep 0.2" });

    const before = try mux.workspace_mgr.activeWindowCount();
    const closed = try mux.closeFocusedWindow();
    const after = try mux.workspace_mgr.activeWindowCount();

    try testing.expectEqual(before - 1, after);
    try testing.expect(!mux.ptys.contains(closed));
    try testing.expect(!mux.stdout_buffers.contains(closed));
}

test "multiplexer detach command toggles detach request flag" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("dev");
    try mux.handleInputBytes(&.{ 0x07, '\\' });
    try testing.expect(mux.consumeDetachRequested());
    try testing.expect(!mux.consumeDetachRequested());
}

test "multiplexer tick surfaces detach request" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("dev");
    try mux.handleInputBytes(&.{ 0x07, '\\' });

    const result = try mux.tick(0, .{ .x = 0, .y = 0, .width = 80, .height = 24 }, .{
        .sigwinch = false,
        .sighup = false,
        .sigterm = false,
    });

    try testing.expect(result.detach_requested);
    try testing.expect(!mux.consumeDetachRequested());
}

test "multiplexer forwards csi sequence and captures mouse metadata" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("dev");
    const win_id = try mux.createCommandWindow("cat", &.{"/bin/cat"});

    try mux.handleInputBytes("\x1b[<0;3;4M");

    var tries: usize = 0;
    while (tries < 40) : (tries += 1) {
        _ = try mux.pollOnce(30);
        const out = try mux.windowOutput(win_id);
        if (std.mem.indexOf(u8, out, "\x1b[<0;3;4M") != null) break;
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }

    const out = try mux.windowOutput(win_id);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[<0;3;4M") != null);

    const mouse = mux.consumeLastMouseEvent() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u16, 0), mouse.button);
    try testing.expectEqual(@as(u16, 3), mouse.x);
    try testing.expectEqual(@as(u16, 4), mouse.y);
    try testing.expect(mouse.pressed);
}
