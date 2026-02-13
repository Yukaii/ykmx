const std = @import("std");
const posix = std.posix;

var got_sigwinch = std.atomic.Value(bool).init(false);
var got_sighup = std.atomic.Value(bool).init(false);
var got_sigterm = std.atomic.Value(bool).init(false);

pub const Snapshot = struct {
    sigwinch: bool,
    sighup: bool,
    sigterm: bool,
};

pub fn installHandlers() void {
    const act: posix.Sigaction = .{
        .handler = .{ .handler = handleSignal },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.RESTART,
    };

    posix.sigaction(posix.SIG.WINCH, &act, null);
    posix.sigaction(posix.SIG.HUP, &act, null);
    posix.sigaction(posix.SIG.TERM, &act, null);
}

pub fn drain() Snapshot {
    return .{
        .sigwinch = got_sigwinch.swap(false, .seq_cst),
        .sighup = got_sighup.swap(false, .seq_cst),
        .sigterm = got_sigterm.swap(false, .seq_cst),
    };
}

fn handleSignal(sig: i32) callconv(.c) void {
    switch (sig) {
        posix.SIG.WINCH => got_sigwinch.store(true, .seq_cst),
        posix.SIG.HUP => got_sighup.store(true, .seq_cst),
        posix.SIG.TERM => got_sigterm.store(true, .seq_cst),
        else => {},
    }
}
