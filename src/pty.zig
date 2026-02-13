const std = @import("std");
const posix = std.posix;

pub const Pty = struct {
    child: std.process.Child,

    pub fn spawnShell(allocator: std.mem.Allocator) !Pty {
        const shell_owned = std.process.getEnvVarOwned(allocator, "SHELL") catch null;
        defer if (shell_owned) |s| allocator.free(s);

        const shell = if (shell_owned) |s| s else "/bin/sh";
        const argv = [_][]const u8{shell};
        return spawnCommand(allocator, &argv);
    }

    pub fn spawnCommand(allocator: std.mem.Allocator, argv: []const []const u8) !Pty {
        if (argv.len == 0) return error.EmptyArgv;

        var child = std.process.Child.init(argv, allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        if (child.stdout) |*out| try setNonBlocking(out.handle);
        if (child.stderr) |*err_out| try setNonBlocking(err_out.handle);

        return .{ .child = child };
    }

    pub fn stdinFile(self: *Pty) ?*std.fs.File {
        if (self.child.stdin) |*f| return f;
        return null;
    }

    pub fn stdoutFile(self: *Pty) ?*std.fs.File {
        if (self.child.stdout) |*f| return f;
        return null;
    }

    pub fn stderrFile(self: *Pty) ?*std.fs.File {
        if (self.child.stderr) |*f| return f;
        return null;
    }

    pub fn write(self: *Pty, bytes: []const u8) !void {
        const stdin_file = self.stdinFile() orelse return error.ChildStdinUnavailable;
        try stdin_file.writeAll(bytes);
    }

    pub fn readStdout(self: *Pty, buf: []u8) !usize {
        const out = self.stdoutFile() orelse return error.ChildStdoutUnavailable;
        return out.read(buf) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => err,
        };
    }

    pub fn readStderr(self: *Pty, buf: []u8) !usize {
        const err_out = self.stderrFile() orelse return error.ChildStderrUnavailable;
        return err_out.read(buf) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => err,
        };
    }

    pub fn terminate(self: *Pty) !void {
        if (self.child.term != null) return;
        _ = try self.child.kill();
    }

    pub fn wait(self: *Pty) !std.process.Child.Term {
        return self.child.wait();
    }

    pub fn deinit(self: *Pty) void {
        if (self.child.term == null) {
            _ = self.child.kill() catch {};
            _ = self.child.wait() catch {};
        } else {
            _ = self.child.wait() catch {};
        }

        self.* = undefined;
    }

    fn setNonBlocking(fd: posix.fd_t) !void {
        var flags = try posix.fcntl(fd, posix.F.GETFL, 0);
        const nonblock_bits_u32: u32 = @bitCast(posix.O{ .NONBLOCK = true });
        flags |= @as(usize, nonblock_bits_u32);
        _ = try posix.fcntl(fd, posix.F.SETFL, flags);
    }
};

test "pty captures command stdout" {
    const testing = std.testing;

    var p = try Pty.spawnCommand(testing.allocator, &.{ "/bin/sh", "-c", "printf 'hello-from-pty\\n'" });
    defer p.deinit();

    var got: [128]u8 = undefined;
    var total: usize = 0;

    var attempts: usize = 0;
    while (attempts < 20) : (attempts += 1) {
        const n = try p.readStdout(got[total..]);
        total += n;
        if (std.mem.indexOf(u8, got[0..total], "hello-from-pty") != null) break;
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }

    try testing.expect(std.mem.indexOf(u8, got[0..total], "hello-from-pty") != null);
}
