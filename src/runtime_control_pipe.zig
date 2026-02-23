const std = @import("std");
const layout = @import("layout.zig");
const multiplexer = @import("multiplexer.zig");
const plugin_manager = @import("plugin_manager.zig");
const runtime_control = @import("runtime_control.zig");

const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("sys/stat.h");
    @cInclude("stdlib.h");
});

pub const ControlPipe = struct {
    allocator: std.mem.Allocator,
    session_id: []u8,
    path: []u8,
    state_path: []u8,
    read_fd: c_int,
    write_fd: c_int,
    buf: std.ArrayListUnmanaged(u8) = .{},

    pub fn init(allocator: std.mem.Allocator, maybe_session_name: ?[]const u8) !ControlPipe {
        const raw_id = maybe_session_name orelse "standalone";
        const session_id = try sanitizeSessionId(allocator, raw_id);
        errdefer allocator.free(session_id);

        const path = try std.fmt.allocPrint(allocator, "/tmp/ykmx-{s}.ctl", .{session_id});
        errdefer allocator.free(path);
        const state_path = try std.fmt.allocPrint(allocator, "/tmp/ykmx-{s}.state", .{session_id});
        errdefer allocator.free(state_path);

        const c_path = try allocator.dupeZ(u8, path);
        defer allocator.free(c_path);
        _ = c.unlink(c_path.ptr);
        if (c.mkfifo(c_path.ptr, 0o600) != 0) return error.ControlPipeCreateFailed;

        const read_fd = c.open(c_path.ptr, c.O_RDONLY | c.O_NONBLOCK);
        if (read_fd < 0) return error.ControlPipeOpenFailed;
        errdefer _ = c.close(read_fd);

        const write_fd = c.open(c_path.ptr, c.O_WRONLY | c.O_NONBLOCK);
        if (write_fd < 0) return error.ControlPipeOpenFailed;
        errdefer _ = c.close(write_fd);

        return .{
            .allocator = allocator,
            .session_id = session_id,
            .path = path,
            .state_path = state_path,
            .read_fd = read_fd,
            .write_fd = write_fd,
        };
    }

    pub fn deinit(self: *ControlPipe) void {
        _ = c.close(self.read_fd);
        _ = c.close(self.write_fd);
        self.buf.deinit(self.allocator);
        if (self.path.len > 0) {
            if (self.allocator.dupeZ(u8, self.path)) |c_path| {
                _ = c.unlink(c_path.ptr);
                self.allocator.free(c_path);
            } else |_| {}
        }
        self.allocator.free(self.path);
        self.allocator.free(self.state_path);
        self.allocator.free(self.session_id);
        self.* = undefined;
    }

    pub fn exportEnv(self: *const ControlPipe) !void {
        const session_z = try self.allocator.dupeZ(u8, self.session_id);
        defer self.allocator.free(session_z);
        const path_z = try self.allocator.dupeZ(u8, self.path);
        defer self.allocator.free(path_z);
        const state_path_z = try self.allocator.dupeZ(u8, self.state_path);
        defer self.allocator.free(state_path_z);
        if (c.setenv("YKMX_SESSION_ID", session_z.ptr, 1) != 0) return error.SetEnvFailed;
        if (c.setenv("YKMX_CONTROL_PIPE", path_z.ptr, 1) != 0) return error.SetEnvFailed;
        if (c.setenv("YKMX_STATE_FILE", state_path_z.ptr, 1) != 0) return error.SetEnvFailed;
    }

    pub fn poll(self: *ControlPipe, mux: *multiplexer.Multiplexer, screen: layout.Rect) !bool {
        var changed = false;
        var scratch: [1024]u8 = undefined;
        while (true) {
            const n = c.read(self.read_fd, &scratch, scratch.len);
            if (n < 0) break;
            if (n == 0) break;
            try self.buf.appendSlice(self.allocator, scratch[0..@intCast(n)]);
        }

        while (std.mem.indexOfScalar(u8, self.buf.items, '\n')) |nl| {
            const line = std.mem.trim(u8, self.buf.items[0..nl], " \t\r");
            if (line.len > 0) {
                changed = (try runtime_control.applyControlCommandLine(mux, screen, line)) or changed;
            }
            consumePrefix(&self.buf, nl + 1);
        }
        return changed;
    }

    pub fn writeState(self: *ControlPipe, mux: *multiplexer.Multiplexer, plugins: *plugin_manager.PluginManager, screen: layout.Rect) !void {
        var text = std.ArrayListUnmanaged(u8){};
        defer text.deinit(self.allocator);
        const w = text.writer(self.allocator);

        const layout_type = try mux.workspace_mgr.activeLayoutType();
        const tab_count = mux.workspace_mgr.tabCount();
        const active_tab_idx = mux.workspace_mgr.activeTabIndex() orelse 0;
        const focused_window_idx = mux.workspace_mgr.focusedWindowIndexActive() catch null;
        const focused_panel_id = mux.popup_mgr.focused_popup_id orelse 0;

        try w.print("session_id={s}\n", .{self.session_id});
        try w.print("layout={s}\n", .{@tagName(layout_type)});
        try w.print("active_tab_index={}\n", .{active_tab_idx});
        try w.print("tab_count={}\n", .{tab_count});
        try w.print("screen={}x{}\n", .{ screen.width, screen.height });
        try w.print("panel_count_visible={}\n", .{mux.popup_mgr.visibleCount()});
        try w.print("focused_panel_id={}\n", .{focused_panel_id});
        try w.print("plugin_hosts={}\n", .{plugins.hostCount()});

        const tab = try mux.workspace_mgr.activeTab();
        for (tab.windows.items, 0..) |win, i| {
            try w.print("window id={} focused={} minimized={} title=", .{
                win.id,
                @as(u8, @intFromBool(focused_window_idx != null and focused_window_idx.? == i)),
                @as(u8, @intFromBool(win.minimized)),
            });
            try writeQuotedString(w, win.title);
            try w.writeByte('\n');
        }

        for (mux.popup_mgr.popups.items) |p| {
            try w.print(
                "panel id={} visible={} focused={} modal={} owner=",
                .{
                    p.id,
                    @as(u8, @intFromBool(p.visible)),
                    @as(u8, @intFromBool(mux.popup_mgr.focused_popup_id != null and mux.popup_mgr.focused_popup_id.? == p.id)),
                    @as(u8, @intFromBool(p.modal)),
                },
            );
            try writeQuotedString(w, p.owner_plugin_name orelse "");
            try w.print(" rect={},{} {}x{} title=", .{ p.rect.x, p.rect.y, p.rect.width, p.rect.height });
            try writeQuotedString(w, p.title);
            try w.writeByte('\n');
        }

        for (plugins.loadReports()) |report| {
            try w.writeAll("plugin name=");
            try writeQuotedString(w, report.plugin_name);
            try w.writeAll(" status=");
            try w.writeAll(@tagName(report.status));
            try w.writeAll(" reason=");
            try writeQuotedString(w, report.reason);
            try w.writeAll(" path=");
            try writeQuotedString(w, report.path);
            try w.writeByte('\n');
        }

        const runtime_hosts = plugins.runtimeHosts(self.allocator) catch &[_]plugin_manager.PluginManager.RuntimeHost{};
        defer if (runtime_hosts.len > 0) self.allocator.free(runtime_hosts);
        for (runtime_hosts) |host| {
            try w.writeAll("plugin_runtime name=");
            try writeQuotedString(w, host.plugin_name);
            try w.print(" alive={} pending_actions={} reason=", .{
                @as(u8, @intFromBool(host.alive)),
                host.pending_actions,
            });
            try writeQuotedString(w, host.death_reason orelse "");
            try w.writeAll(" stderr_tail=");
            try writeQuotedString(w, host.stderr_tail);
            try w.writeByte('\n');
        }

        try mux.appendCommandStateLines(&text, self.allocator);

        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{self.state_path});
        defer self.allocator.free(tmp_path);
        var f = try std.fs.cwd().createFile(tmp_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll(text.items);
        try std.fs.cwd().rename(tmp_path, self.state_path);
    }
};

fn consumePrefix(buf: *std.ArrayListUnmanaged(u8), n: usize) void {
    const remaining = buf.items.len - n;
    if (remaining > 0) @memmove(buf.items[0..remaining], buf.items[n..]);
    buf.items.len = remaining;
}

fn writeQuotedString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0...8, 11...12, 14...31 => try writer.print("\\u00{x:0>2}", .{ch}),
            else => try writer.writeByte(ch),
        }
    }
    try writer.writeByte('"');
}

fn sanitizeSessionId(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);
    for (raw) |ch| {
        const ok = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_' or ch == '-' or ch == '.';
        try out.append(allocator, if (ok) ch else '_');
    }
    if (out.items.len == 0) try out.append(allocator, 's');
    return out.toOwnedSlice(allocator);
}
