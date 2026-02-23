const std = @import("std");
const input_mod = @import("input.zig");
const runtime_command_state = @import("runtime_command_state.zig");

const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
});

pub fn runControlCli(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0 or std.mem.eql(u8, args[0], "help")) {
        var buf: [1024]u8 = undefined;
        var w = std.fs.File.stdout().writer(&buf);
        const out = &w.interface;
        try out.writeAll(
            \\ykmx ctl usage:
            \\  ykmx ctl new-window
            \\  ykmx ctl close-window
            \\  ykmx ctl open-popup [--cwd <path>] [--x N --y N --width N --height N] [--] <program> [args...]
            \\  ykmx ctl open-panel x y width height [--cwd <path>]
            \\  ykmx ctl hide-panel <panel_id>
            \\  ykmx ctl show-panel <panel_id>
            \\  ykmx ctl status
            \\  ykmx ctl list-windows
            \\  ykmx ctl list-panels
            \\  ykmx ctl list-plugins
            \\  ykmx ctl list-commands [--format text|json|jsonl]
            \\  ykmx ctl command <name>
            \\  ykmx ctl json '<json>'
            \\
            \\Uses $YKMX_CONTROL_PIPE (actions) and $YKMX_STATE_FILE (listing).
            \\
        );
        try out.flush();
        return;
    }

    if (std.mem.eql(u8, args[0], "status") or std.mem.eql(u8, args[0], "list-windows") or std.mem.eql(u8, args[0], "list-panels") or std.mem.eql(u8, args[0], "list-plugins") or std.mem.eql(u8, args[0], "list-commands")) {
        const state_path = resolveStatePathForCli(allocator) catch |err| switch (err) {
            error.MissingControlPipeEnv => return writeControlEnvHint(),
            else => return err,
        };
        defer allocator.free(state_path);
        const content = try std.fs.cwd().readFileAlloc(allocator, state_path, 1024 * 1024);
        defer allocator.free(content);

        var buf: [4096]u8 = undefined;
        var w = std.fs.File.stdout().writer(&buf);
        const out = &w.interface;

        if (std.mem.eql(u8, args[0], "status")) {
            try out.writeAll(content);
        } else if (std.mem.eql(u8, args[0], "list-commands")) {
            var format: []const u8 = "text";
            if (args.len >= 2) {
                if (std.mem.eql(u8, args[1], "--json")) {
                    format = "json";
                } else if (std.mem.eql(u8, args[1], "--format")) {
                    if (args.len < 3) return error.InvalidControlArgs;
                    format = args[2];
                } else {
                    return error.InvalidControlArgs;
                }
            }

            if (std.mem.eql(u8, format, "text")) {
                var it = std.mem.splitScalar(u8, content, '\n');
                while (it.next()) |line| {
                    if (!std.mem.startsWith(u8, line, "command ")) continue;
                    try out.writeAll(line);
                    try out.writeByte('\n');
                }
            } else if (std.mem.eql(u8, format, "json")) {
                var json = std.ArrayListUnmanaged(u8){};
                defer json.deinit(allocator);
                try runtime_command_state.renderCommandListJson(allocator, &json, content, false);
                try out.writeAll(json.items);
                try out.writeByte('\n');
            } else if (std.mem.eql(u8, format, "jsonl")) {
                var jsonl = std.ArrayListUnmanaged(u8){};
                defer jsonl.deinit(allocator);
                try runtime_command_state.renderCommandListJson(allocator, &jsonl, content, true);
                try out.writeAll(jsonl.items);
                if (jsonl.items.len == 0 or jsonl.items[jsonl.items.len - 1] != '\n') {
                    try out.writeByte('\n');
                }
            } else {
                return error.InvalidControlArgs;
            }
        } else {
            var it = std.mem.splitScalar(u8, content, '\n');
            while (it.next()) |line| {
                if (line.len == 0) continue;
                if (std.mem.eql(u8, args[0], "list-windows")) {
                    if (!std.mem.startsWith(u8, line, "window ")) continue;
                } else if (std.mem.eql(u8, args[0], "list-plugins")) {
                    if (!std.mem.startsWith(u8, line, "plugin ")) {
                        if (!std.mem.startsWith(u8, line, "plugin_runtime ")) continue;
                    }
                } else {
                    if (!std.mem.startsWith(u8, line, "panel ")) continue;
                }
                try out.writeAll(line);
                try out.writeByte('\n');
            }
        }
        try out.flush();
        return;
    }

    const pipe_path = std.process.getEnvVarOwned(allocator, "YKMX_CONTROL_PIPE") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return writeControlEnvHint(),
        else => return err,
    };
    defer allocator.free(pipe_path);
    const pipe_z = try allocator.dupeZ(u8, pipe_path);
    defer allocator.free(pipe_z);

    var line = std.ArrayListUnmanaged(u8){};
    defer line.deinit(allocator);

    if (std.mem.eql(u8, args[0], "json")) {
        if (args.len < 2) return error.InvalidControlArgs;
        try line.appendSlice(allocator, args[1]);
    } else if (std.mem.eql(u8, args[0], "new-window")) {
        try line.appendSlice(allocator, "{\"v\":1,\"command\":\"new_window\"}");
    } else if (std.mem.eql(u8, args[0], "close-window")) {
        try line.appendSlice(allocator, "{\"v\":1,\"command\":\"close_window\"}");
    } else if (std.mem.eql(u8, args[0], "open-popup")) {
        var cwd: ?[]const u8 = null;
        var x: ?u16 = null;
        var y: ?u16 = null;
        var width: ?u16 = null;
        var height: ?u16 = null;
        var i: usize = 1;
        while (i < args.len) {
            if (std.mem.eql(u8, args[i], "--cwd")) {
                if (i + 1 >= args.len) return error.InvalidControlArgs;
                cwd = args[i + 1];
                i += 2;
                continue;
            }
            if (std.mem.eql(u8, args[i], "--x")) {
                if (i + 1 >= args.len) return error.InvalidControlArgs;
                x = try std.fmt.parseInt(u16, args[i + 1], 10);
                i += 2;
                continue;
            }
            if (std.mem.eql(u8, args[i], "--y")) {
                if (i + 1 >= args.len) return error.InvalidControlArgs;
                y = try std.fmt.parseInt(u16, args[i + 1], 10);
                i += 2;
                continue;
            }
            if (std.mem.eql(u8, args[i], "--width")) {
                if (i + 1 >= args.len) return error.InvalidControlArgs;
                width = try std.fmt.parseInt(u16, args[i + 1], 10);
                i += 2;
                continue;
            }
            if (std.mem.eql(u8, args[i], "--height")) {
                if (i + 1 >= args.len) return error.InvalidControlArgs;
                height = try std.fmt.parseInt(u16, args[i + 1], 10);
                i += 2;
                continue;
            }
            if (std.mem.eql(u8, args[i], "--")) {
                i += 1;
                break;
            }
            break;
        }
        const argv = args[i..];
        const has_any_rect = x != null or y != null or width != null or height != null;
        if (has_any_rect and !(x != null and y != null and width != null and height != null)) {
            return error.InvalidControlArgs;
        }

        try line.appendSlice(allocator, "{\"v\":1,\"command\":\"open_popup\"");
        if (cwd) |dir| {
            try line.appendSlice(allocator, ",\"cwd\":");
            try appendJsonString(&line, allocator, dir);
        }
        if (x) |value| try line.writer(allocator).print(",\"x\":{}", .{value});
        if (y) |value| try line.writer(allocator).print(",\"y\":{}", .{value});
        if (width) |value| try line.writer(allocator).print(",\"width\":{}", .{value});
        if (height) |value| try line.writer(allocator).print(",\"height\":{}", .{value});
        if (argv.len > 0) {
            try line.appendSlice(allocator, ",\"argv\":[");
            for (argv, 0..) |arg, j| {
                if (j > 0) try line.append(allocator, ',');
                try appendJsonString(&line, allocator, arg);
            }
            try line.append(allocator, ']');
        }
        try line.append(allocator, '}');
    } else if (std.mem.eql(u8, args[0], "open-panel")) {
        if (args.len < 5) return error.InvalidControlArgs;
        const x = try std.fmt.parseInt(u16, args[1], 10);
        const y = try std.fmt.parseInt(u16, args[2], 10);
        const width = try std.fmt.parseInt(u16, args[3], 10);
        const height = try std.fmt.parseInt(u16, args[4], 10);

        var cwd: ?[]const u8 = null;
        var i: usize = 5;
        while (i < args.len) {
            if (std.mem.eql(u8, args[i], "--cwd")) {
                if (i + 1 >= args.len) return error.InvalidControlArgs;
                cwd = args[i + 1];
                i += 2;
                continue;
            }
            return error.InvalidControlArgs;
        }

        try line.appendSlice(allocator, "{\"v\":1,\"command\":\"open_panel_rect\",");
        try line.writer(allocator).print("\"x\":{},\"y\":{},\"width\":{},\"height\":{},\"modal\":false", .{ x, y, width, height });
        if (cwd) |dir| {
            try line.appendSlice(allocator, ",\"cwd\":");
            try appendJsonString(&line, allocator, dir);
        }
        try line.append(allocator, '}');
    } else if (std.mem.eql(u8, args[0], "hide-panel")) {
        if (args.len < 2) return error.InvalidControlArgs;
        try line.writer(allocator).print(
            "{{\"v\":1,\"command\":\"set_panel_visibility\",\"panel_id\":{},\"visible\":false}}",
            .{try std.fmt.parseInt(u32, args[1], 10)},
        );
    } else if (std.mem.eql(u8, args[0], "show-panel")) {
        if (args.len < 2) return error.InvalidControlArgs;
        try line.writer(allocator).print(
            "{{\"v\":1,\"command\":\"set_panel_visibility\",\"panel_id\":{},\"visible\":true}}",
            .{try std.fmt.parseInt(u32, args[1], 10)},
        );
    } else if (std.mem.eql(u8, args[0], "command")) {
        if (args.len < 2) return error.InvalidControlArgs;
        if (!input_mod.isValidCommandName(args[1])) return error.InvalidControlArgs;
        try line.writer(allocator).print(
            "{{\"v\":1,\"command\":\"dispatch_plugin_command\",\"command_name\":\"{s}\"}}",
            .{args[1]},
        );
    } else {
        return error.InvalidControlArgs;
    }
    try line.append(allocator, '\n');

    const fd = c.open(pipe_z.ptr, c.O_WRONLY);
    if (fd < 0) return error.ControlPipeOpenFailed;
    defer _ = c.close(fd);
    _ = c.write(fd, line.items.ptr, line.items.len);
}

fn writeControlEnvHint() !void {
    var buf: [256]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    const err_out = &w.interface;
    try err_out.writeAll("ykmx ctl requires a running ykmx session shell (missing YKMX_CONTROL_PIPE/YKMX_STATE_FILE).\n");
    try err_out.flush();
}

fn resolveStatePathForCli(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "YKMX_STATE_FILE")) |state_path| {
        return state_path;
    } else |_| {}

    const pipe_path = std.process.getEnvVarOwned(allocator, "YKMX_CONTROL_PIPE") catch return error.MissingControlPipeEnv;
    defer allocator.free(pipe_path);

    if (std.mem.endsWith(u8, pipe_path, ".ctl")) {
        return std.fmt.allocPrint(allocator, "{s}.state", .{pipe_path[0 .. pipe_path.len - 4]});
    }
    return std.fmt.allocPrint(allocator, "{s}.state", .{pipe_path});
}

fn appendJsonString(
    out: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    s: []const u8,
) !void {
    try out.append(allocator, '"');
    for (s) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            0...8, 11...12, 14...31 => try out.writer(allocator).print("\\u00{x:0>2}", .{ch}),
            else => try out.append(allocator, ch),
        }
    }
    try out.append(allocator, '"');
}
