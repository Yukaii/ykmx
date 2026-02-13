const std = @import("std");

pub const Env = struct {
    in_session: bool,
    session_name: ?[]u8,
    socket_dir: ?[]u8,

    pub fn deinit(self: *Env, allocator: std.mem.Allocator) void {
        if (self.session_name) |v| allocator.free(v);
        if (self.socket_dir) |v| allocator.free(v);
        self.* = undefined;
    }

    pub fn detachCurrentSession(self: *const Env, allocator: std.mem.Allocator) !bool {
        if (!self.in_session) return false;
        const session = self.session_name orelse return false;

        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "zmx", "detach", session },
            .max_output_bytes = 16 * 1024,
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        switch (result.term) {
            .Exited => |code| {
                if (code != 0) return error.ZmxDetachFailed;
            },
            else => return error.ZmxDetachFailed,
        }

        return true;
    }
};

pub fn buildAttachArgv(
    allocator: std.mem.Allocator,
    session: []const u8,
    program: []const u8,
    args: []const []const u8,
) ![][]const u8 {
    var out = try allocator.alloc([]const u8, 4 + args.len);
    out[0] = "zmx";
    out[1] = "attach";
    out[2] = session;
    out[3] = program;
    for (args, 0..) |arg, i| out[4 + i] = arg;
    return out;
}

pub fn detect(allocator: std.mem.Allocator) !Env {
    const session_name = std.process.getEnvVarOwned(allocator, "ZMX_SESSION") catch null;
    const zmx_dir = std.process.getEnvVarOwned(allocator, "ZMX_DIR") catch null;

    if (zmx_dir) |dir| {
        return .{
            .in_session = session_name != null,
            .session_name = session_name,
            .socket_dir = dir,
        };
    }

    const xdg_runtime_dir = std.process.getEnvVarOwned(allocator, "XDG_RUNTIME_DIR") catch null;
    if (xdg_runtime_dir) |base| {
        defer allocator.free(base);
        return .{
            .in_session = session_name != null,
            .session_name = session_name,
            .socket_dir = try std.fmt.allocPrint(allocator, "{s}/zmx", .{base}),
        };
    }

    return .{
        .in_session = session_name != null,
        .session_name = session_name,
        .socket_dir = null,
    };
}

test "zmx socket dir helper formats runtime dir" {
    const testing = std.testing;
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/zmx", .{"/tmp/runtime"});
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/tmp/runtime/zmx", path);
}

test "zmx detach helper returns false when not in session" {
    const testing = std.testing;
    const env = Env{
        .in_session = false,
        .session_name = null,
        .socket_dir = null,
    };

    const detached = try env.detachCurrentSession(testing.allocator);
    try testing.expect(!detached);
}

test "zmx attach argv builder includes session and program args" {
    const testing = std.testing;
    const argv = try buildAttachArgv(testing.allocator, "dev", "ykwm", &.{ "--config", "foo" });
    defer testing.allocator.free(argv);

    try testing.expectEqual(@as(usize, 6), argv.len);
    try testing.expectEqualStrings("zmx", argv[0]);
    try testing.expectEqualStrings("attach", argv[1]);
    try testing.expectEqualStrings("dev", argv[2]);
    try testing.expectEqualStrings("ykwm", argv[3]);
    try testing.expectEqualStrings("--config", argv[4]);
    try testing.expectEqualStrings("foo", argv[5]);
}
