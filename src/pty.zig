const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("util.h");
    @cInclude("unistd.h");
    @cInclude("signal.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/wait.h");
});

pub const Pty = struct {
    allocator: std.mem.Allocator,
    pid: posix.pid_t,
    master: std.fs.File,
    exited: bool = false,

    pub fn spawnShell(allocator: std.mem.Allocator) !Pty {
        const shell_owned = std.process.getEnvVarOwned(allocator, "SHELL") catch null;
        defer if (shell_owned) |s| allocator.free(s);

        const shell = if (shell_owned) |s| s else "/bin/sh";
        const argv = [_][]const u8{ shell, "-i" };
        return spawnCommand(allocator, &argv);
    }

    pub fn spawnCommand(allocator: std.mem.Allocator, argv: []const []const u8) !Pty {
        if (builtin.os.tag == .windows) return error.UnsupportedPlatform;
        if (argv.len == 0) return error.EmptyArgv;

        var c_argv = try allocator.alloc(?[*:0]u8, argv.len + 1);
        defer allocator.free(c_argv);

        for (argv, 0..) |arg, i| {
            c_argv[i] = try allocator.dupeZ(u8, arg);
        }
        c_argv[argv.len] = null;
        defer {
            for (c_argv[0..argv.len]) |maybe| {
                if (maybe) |z| allocator.free(std.mem.sliceTo(z, 0));
            }
        }

        var ws: c.struct_winsize = .{
            .ws_row = 24,
            .ws_col = 80,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };

        var master_fd: c_int = -1;
        const pid_raw = c.forkpty(&master_fd, null, null, &ws);
        if (pid_raw < 0) return error.ForkPtyFailed;

        if (pid_raw == 0) {
            _ = c.execvp(c_argv[0].?, @ptrCast(c_argv.ptr));
            c._exit(127);
        }

        const master_file: std.fs.File = .{ .handle = @intCast(master_fd) };
        try setNonBlocking(master_file.handle);

        return .{
            .allocator = allocator,
            .pid = @intCast(pid_raw),
            .master = master_file,
            .exited = false,
        };
    }

    pub fn stdinFile(self: *Pty) ?*std.fs.File {
        return &self.master;
    }

    pub fn stdoutFile(self: *Pty) ?*std.fs.File {
        return &self.master;
    }

    pub fn stderrFile(_: *Pty) ?*std.fs.File {
        return null;
    }

    pub fn write(self: *Pty, bytes: []const u8) !void {
        try self.master.writeAll(bytes);
    }

    pub fn readStdout(self: *Pty, buf: []u8) !usize {
        return self.master.read(buf) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => err,
        };
    }

    pub fn readStderr(_: *Pty, _: []u8) !usize {
        return 0;
    }

    pub fn resize(self: *Pty, rows: u16, cols: u16) !void {
        var ws: c.struct_winsize = .{
            .ws_row = @intCast(rows),
            .ws_col = @intCast(cols),
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };

        if (c.ioctl(self.master.handle, c.TIOCSWINSZ, &ws) != 0) {
            return error.IoctlFailed;
        }
    }

    pub fn terminate(self: *Pty) !void {
        if (self.exited) return;
        try posix.kill(self.pid, posix.SIG.TERM);
    }

    pub fn wait(self: *Pty) !u32 {
        if (self.exited) return 0;
        const result = posix.waitpid(self.pid, 0);
        self.exited = true;
        return result.status;
    }

    pub fn reapIfExited(self: *Pty) !bool {
        if (self.exited) return true;

        var status: c_int = 0;
        const pid = c.waitpid(self.pid, &status, c.WNOHANG);
        if (pid == 0) return false;
        if (pid < 0) return error.WaitPidFailed;

        self.exited = true;
        return true;
    }

    pub fn deinit(self: *Pty) void {
        if (!self.exited) {
            _ = posix.kill(self.pid, posix.SIG.TERM) catch {};
            _ = self.wait() catch {};
        }
        self.master.close();
        self.* = undefined;
    }

    pub fn deinitNoWait(self: *Pty) void {
        if (!self.exited) {
            _ = posix.kill(self.pid, posix.SIG.TERM) catch {};
            _ = self.reapIfExited() catch {};
        }
        self.master.close();
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

    var got: [256]u8 = undefined;
    var total: usize = 0;

    var attempts: usize = 0;
    while (attempts < 40) : (attempts += 1) {
        const n = try p.readStdout(got[total..]);
        total += n;
        if (std.mem.indexOf(u8, got[0..total], "hello-from-pty") != null) break;
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }

    try testing.expect(std.mem.indexOf(u8, got[0..total], "hello-from-pty") != null);
}

test "pty resize ioctl path succeeds" {
    const testing = std.testing;

    var p = try Pty.spawnCommand(testing.allocator, &.{ "/bin/sh", "-c", "sleep 0.1" });
    defer p.deinit();

    try p.resize(30, 100);
}

test "pty reapIfExited returns true after command exits" {
    const testing = std.testing;

    var p = try Pty.spawnCommand(testing.allocator, &.{ "/bin/sh", "-c", "exit 0" });
    defer p.deinit();

    var exited = false;
    var tries: usize = 0;
    while (tries < 40) : (tries += 1) {
        exited = try p.reapIfExited();
        if (exited) break;
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }

    try testing.expect(exited);
}
