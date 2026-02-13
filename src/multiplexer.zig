const std = @import("std");
const layout = @import("layout.zig");
const workspace = @import("workspace.zig");
const pty_mod = @import("pty.zig");

pub const Multiplexer = struct {
    allocator: std.mem.Allocator,
    workspace_mgr: workspace.WorkspaceManager,
    ptys: std.AutoHashMapUnmanaged(u32, pty_mod.Pty) = .{},
    stdout_buffers: std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(u8)) = .{},

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
