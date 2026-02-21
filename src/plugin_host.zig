const std = @import("std");
const layout = @import("layout.zig");
const posix = std.posix;

pub const PluginHost = struct {
    pub const Action = union(enum) {
        cycle_layout,
        set_layout: layout.LayoutType,
        set_master_ratio_permille: u16,
    };

    allocator: std.mem.Allocator,
    child: std.process.Child,
    alive: bool = true,
    next_request_id: u64 = 1,
    read_buf: std.ArrayListUnmanaged(u8) = .{},
    pending_actions: std.ArrayListUnmanaged(Action) = .{},

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

    const ActionEnvelope = struct {
        v: ?u8 = null,
        action: ?[]const u8 = null,
        layout: ?[]const u8 = null,
        value: ?u16 = null,
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
        self.pending_actions.deinit(self.allocator);
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

    pub fn drainActions(self: *PluginHost, allocator: std.mem.Allocator) ![]Action {
        var matched: ?[]layout.Rect = null;
        try self.readAvailableStdout();
        try self.processBufferedLines(allocator, null, &matched);

        if (self.pending_actions.items.len == 0) return allocator.alloc(Action, 0);
        const out = try allocator.alloc(Action, self.pending_actions.items.len);
        @memcpy(out, self.pending_actions.items);
        self.pending_actions.clearRetainingCapacity();
        return out;
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
        var matched: ?[]layout.Rect = null;
        try self.processBufferedLines(allocator, request_id, &matched);
        return matched;
    }

    fn processBufferedLines(
        self: *PluginHost,
        allocator: std.mem.Allocator,
        expected_request_id: ?u64,
        matched: *?[]layout.Rect,
    ) !void {
        while (std.mem.indexOfScalar(u8, self.read_buf.items, '\n')) |nl_idx| {
            const line = self.read_buf.items[0..nl_idx];
            if (expected_request_id) |request_id| {
                if (try self.parseLayoutResponseLine(allocator, request_id, line)) |rects| {
                    matched.* = rects;
                }
            }
            if (self.parseActionLine(allocator, line)) |action| {
                try self.pending_actions.append(self.allocator, action);
            }
            self.consumeReadBufPrefix(nl_idx + 1);
        }
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
        if (in_rects.len == 0) {
            const empty = try allocator.alloc(layout.Rect, 0);
            return @as(?[]layout.Rect, empty);
        }

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

    fn parseActionLine(self: *PluginHost, allocator: std.mem.Allocator, line: []const u8) ?Action {
        _ = self;
        if (line.len == 0) return null;

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const parsed = std.json.parseFromSlice(ActionEnvelope, arena.allocator(), line, .{}) catch return null;
        const envelope = parsed.value;
        const action_name = envelope.action orelse return null;

        if (std.mem.eql(u8, action_name, "cycle_layout")) return .cycle_layout;
        if (std.mem.eql(u8, action_name, "set_layout")) {
            const layout_name = envelope.layout orelse return null;
            const layout_type = parseLayoutType(layout_name) orelse return null;
            return .{ .set_layout = layout_type };
        }
        if (std.mem.eql(u8, action_name, "set_master_ratio_permille")) {
            const value = envelope.value orelse return null;
            return .{ .set_master_ratio_permille = value };
        }
        return null;
    }

    fn parseLayoutType(name: []const u8) ?layout.LayoutType {
        if (std.mem.eql(u8, name, "vertical_stack")) return .vertical_stack;
        if (std.mem.eql(u8, name, "horizontal_stack")) return .horizontal_stack;
        if (std.mem.eql(u8, name, "grid")) return .grid;
        if (std.mem.eql(u8, name, "paperwm")) return .paperwm;
        if (std.mem.eql(u8, name, "fullscreen")) return .fullscreen;
        return null;
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
