const std = @import("std");
const layout = @import("layout.zig");

const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("sys/ioctl.h");
    @cInclude("termios.h");
    @cInclude("fcntl.h");
});

pub const RuntimeSize = struct {
    cols: u16,
    rows: u16,
};

pub const RuntimeTerminal = struct {
    had_termios: bool = false,
    original_termios: c.struct_termios = undefined,
    original_stdin_flags: c_int = 0,
    original_stdout_flags: c_int = 0,

    pub fn enter() !RuntimeTerminal {
        var rt: RuntimeTerminal = .{};

        rt.original_stdin_flags = c.fcntl(c.STDIN_FILENO, c.F_GETFL, @as(c_int, 0));
        if (rt.original_stdin_flags >= 0) {
            _ = c.fcntl(c.STDIN_FILENO, c.F_SETFL, rt.original_stdin_flags | c.O_NONBLOCK);
        }

        rt.original_stdout_flags = c.fcntl(c.STDOUT_FILENO, c.F_GETFL, @as(c_int, 0));
        if (rt.original_stdout_flags >= 0) {
            _ = c.fcntl(c.STDOUT_FILENO, c.F_SETFL, rt.original_stdout_flags & ~@as(c_int, c.O_NONBLOCK));
        }

        var termios_state: c.struct_termios = undefined;
        if (c.tcgetattr(c.STDIN_FILENO, &termios_state) == 0) {
            rt.had_termios = true;
            rt.original_termios = termios_state;
            var raw = termios_state;
            raw.c_lflag &= ~@as(c_uint, @intCast(c.ECHO | c.ICANON | c.ISIG));
            raw.c_iflag &= ~@as(c_uint, @intCast(c.IXON | c.ICRNL));
            raw.c_oflag &= ~@as(c_uint, @intCast(c.OPOST));
            raw.c_cc[c.VMIN] = 0;
            raw.c_cc[c.VTIME] = 0;
            _ = c.tcsetattr(c.STDIN_FILENO, c.TCSAFLUSH, &raw);
        }

        const enter_seq = "\x1b[?1049h\x1b[?1000h\x1b[?1002h\x1b[?1003h\x1b[?1006h\x1b[?7l\x1b[?25l";
        _ = c.write(c.STDOUT_FILENO, enter_seq, enter_seq.len);
        return rt;
    }

    pub fn leave(self: *RuntimeTerminal) void {
        const leave_seq = "\x1b[?1006l\x1b[?1003l\x1b[?1002l\x1b[?1000l\x1b[?7h\x1b[?25h\x1b[?1049l";
        _ = c.write(c.STDOUT_FILENO, leave_seq, leave_seq.len);
        if (self.had_termios) {
            _ = c.tcsetattr(c.STDIN_FILENO, c.TCSAFLUSH, &self.original_termios);
        }
        if (self.original_stdin_flags >= 0) {
            _ = c.fcntl(c.STDIN_FILENO, c.F_SETFL, self.original_stdin_flags);
        }
        if (self.original_stdout_flags >= 0) {
            _ = c.fcntl(c.STDOUT_FILENO, c.F_SETFL, self.original_stdout_flags);
        }
    }
};

pub fn getTerminalSize() RuntimeSize {
    var ws: c.struct_winsize = undefined;
    if (c.ioctl(c.STDOUT_FILENO, c.TIOCGWINSZ, &ws) == 0) {
        const cols: u16 = if (ws.ws_col > 0) @intCast(ws.ws_col) else 80;
        const rows: u16 = if (ws.ws_row > 0) @intCast(ws.ws_row) else 24;
        return .{ .cols = cols, .rows = rows };
    }
    return .{ .cols = 80, .rows = 24 };
}

pub fn contentRect(size: RuntimeSize) layout.Rect {
    const usable_rows: u16 = if (size.rows > 3) size.rows - 3 else size.rows;
    return .{ .x = 0, .y = 0, .width = size.cols, .height = usable_rows };
}

pub fn readStdinNonBlocking(buf: []u8) !usize {
    return std.posix.read(c.STDIN_FILENO, buf);
}
