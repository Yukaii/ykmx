const std = @import("std");
const layout = @import("layout.zig");
const posix = std.posix;

pub const PluginHost = struct {
    allocator: std.mem.Allocator,
    child: std.process.Child,
    alive: bool = true,
    next_request_id: u64 = 1,
    read_buf: std.ArrayListUnmanaged(u8) = .{},

    const LayoutRect = struct {
        x: u16,
        y: u16,
        width: u16,
        height: u16,
    };

    const LayoutResponse = struct {
        v: ?u8 = null,
        id: ?u64 = null,
        fallback: ?bool = null,
        rects: ?[]LayoutRect = null,
    };

    pub fn start(allocator: std.mem.Allocator, plugin_dir: []const u8) !PluginHost {
        const entry = try std.fs.path.join(allocator, &.{ plugin_dir, "index.ts" });
        defer allocator.free(entry);
        std.fs.cwd().access(entry, .{}) catch return error.PluginEntryNotFound;

        var argv = [_][]const u8{ "bun", "run", entry };
        var child = std.process.Child.init(&argv, allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        child.cwd = plugin_dir;
        try child.spawn();

        if (child.stdout) |stdout_file| {
            try setNonBlocking(stdout_file.handle);
        }

        return .{
            .allocator = allocator,
            .child = child,
        };
    }

    pub fn deinit(self: *PluginHost) void {
        self.read_buf.deinit(self.allocator);
        if (self.alive) {
            _ = self.child.kill() catch {};
            self.alive = false;
        } else {
            _ = self.child.wait() catch {};
        }
        self.* = undefined;
    }

    pub fn emitStart(self: *PluginHost, layout_type: layout.LayoutType) !void {
        var buf: [128]u8 = undefined;
        const line = try std.fmt.bufPrint(
            &buf,
            "{{\"v\":1,\"event\":\"on_start\",\"layout\":\"{s}\"}}\n",
            .{@tagName(layout_type)},
        );
        try self.emitLine(line);
    }

    pub fn emitLayoutChanged(self: *PluginHost, layout_type: layout.LayoutType) !void {
        var buf: [160]u8 = undefined;
        const line = try std.fmt.bufPrint(
            &buf,
            "{{\"v\":1,\"event\":\"on_layout_changed\",\"layout\":\"{s}\"}}\n",
            .{@tagName(layout_type)},
        );
        try self.emitLine(line);
    }

    pub fn emitShutdown(self: *PluginHost) !void {
        try self.emitLine("{\"v\":1,\"event\":\"on_shutdown\"}\n");
    }

    pub fn requestLayout(
        self: *PluginHost,
        allocator: std.mem.Allocator,
        params: layout.LayoutParams,
        timeout_ms: u16,
    ) !?[]layout.Rect {
        if (!self.alive) return null;

        const req_id = self.next_request_id;
        self.next_request_id += 1;

        var req_buf: [512]u8 = undefined;
        const req_line = try std.fmt.bufPrint(
            &req_buf,
            "{{\"v\":1,\"id\":{},\"event\":\"on_compute_layout\",\"params\":{{\"layout\":\"{s}\",\"screen\":{{\"x\":{},\"y\":{},\"width\":{},\"height\":{}}},\"window_count\":{},\"focused_index\":{},\"master_count\":{},\"master_ratio_permille\":{},\"gap\":{}}}}}\n",
            .{
                req_id,
                @tagName(params.layout),
                params.screen.x,
                params.screen.y,
                params.screen.width,
                params.screen.height,
                params.window_count,
                params.focused_index,
                params.master_count,
                params.master_ratio_permille,
                params.gap,
            },
        );
        try self.emitLine(req_line);

        const start_ms = std.time.milliTimestamp();
        while (std.time.milliTimestamp() - start_ms < timeout_ms) {
            if (try self.tryReadMatchingResponse(allocator, req_id)) |rects| {
                return rects;
            }
            if (!self.alive) return null;
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
        return null;
    }

    fn emitLine(self: *PluginHost, line: []const u8) !void {
        if (!self.alive) return;
        const stdin_file = self.child.stdin orelse {
            self.alive = false;
            return;
        };
        stdin_file.writeAll(line) catch |err| switch (err) {
            error.BrokenPipe, error.NotOpenForWriting => {
                self.alive = false;
                return;
            },
            else => return err,
        };
    }

    fn tryReadMatchingResponse(
        self: *PluginHost,
        allocator: std.mem.Allocator,
        request_id: u64,
    ) !?[]layout.Rect {
        if (!self.alive) return null;
        try self.readAvailableStdout();

        while (std.mem.indexOfScalar(u8, self.read_buf.items, '\n')) |nl_idx| {
            const line = self.read_buf.items[0..nl_idx];
            if (try self.parseLayoutResponseLine(allocator, request_id, line)) |rects| {
                self.consumeReadBufPrefix(nl_idx + 1);
                return rects;
            }
            self.consumeReadBufPrefix(nl_idx + 1);
        }
        return null;
    }

    fn parseLayoutResponseLine(
        self: *PluginHost,
        allocator: std.mem.Allocator,
        request_id: u64,
        line: []const u8,
    ) !?[]layout.Rect {
        _ = self;
        if (line.len == 0) return null;

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const parsed = std.json.parseFromSlice(LayoutResponse, arena.allocator(), line, .{}) catch return null;
        const response = parsed.value;
        if (response.id == null or response.id.? != request_id) return null;
        if (response.fallback orelse false) return null;
        const in_rects = response.rects orelse return null;
        if (in_rects.len == 0) return allocator.alloc(layout.Rect, 0);

        const rects = try allocator.alloc(layout.Rect, in_rects.len);
        for (in_rects, 0..) |r, i| {
            rects[i] = .{
                .x = r.x,
                .y = r.y,
                .width = r.width,
                .height = r.height,
            };
        }
        return rects;
    }

    fn readAvailableStdout(self: *PluginHost) !void {
        const stdout_file = self.child.stdout orelse {
            self.alive = false;
            return;
        };

        var scratch: [1024]u8 = undefined;
        while (true) {
            const n = stdout_file.read(&scratch) catch |err| switch (err) {
                error.WouldBlock => break,
                else => return err,
            };
            if (n == 0) {
                self.alive = false;
                break;
            }
            try self.read_buf.appendSlice(self.allocator, scratch[0..n]);
        }
    }

    fn consumeReadBufPrefix(self: *PluginHost, n: usize) void {
        const remaining = self.read_buf.items.len - n;
        if (remaining > 0) {
            @memmove(self.read_buf.items[0..remaining], self.read_buf.items[n..]);
        }
        self.read_buf.items.len = remaining;
    }

    fn setNonBlocking(fd: posix.fd_t) !void {
        var flags = try posix.fcntl(fd, posix.F.GETFL, 0);
        const nonblock_bits_u32: u32 = @bitCast(posix.O{ .NONBLOCK = true });
        flags |= @as(usize, nonblock_bits_u32);
        _ = try posix.fcntl(fd, posix.F.SETFL, flags);
    }
};
