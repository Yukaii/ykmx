const std = @import("std");

pub const Command = enum {
    create_window,
    close_window,
    next_tab,
    prev_tab,
    next_window,
    prev_window,
    detach,
};

pub const Event = union(enum) {
    forward: u8,
    forward_sequence: ForwardSequence,
    command: Command,
    noop,
};

pub const MouseEvent = struct {
    button: u16,
    x: u16,
    y: u16,
    pressed: bool,
};

pub const ForwardSequence = struct {
    buf: [64]u8 = undefined,
    len: u8 = 0,
    mouse: ?MouseEvent = null,

    pub fn slice(self: *const ForwardSequence) []const u8 {
        return self.buf[0..self.len];
    }
};

const EscapeState = enum {
    none,
    esc,
    csi,
};

pub const Router = struct {
    prefix_key: u8 = 0x07, // Ctrl+G
    waiting_for_command: bool = false,
    escape_state: EscapeState = .none,
    esc_buf: [64]u8 = undefined,
    esc_len: u8 = 0,

    pub fn feedByte(self: *Router, b: u8) Event {
        if (self.escape_state != .none) {
            return self.feedEscapeByte(b);
        }

        if (self.waiting_for_command) {
            self.waiting_for_command = false;
            return switch (b) {
                'c' => .{ .command = .create_window },
                'x' => .{ .command = .close_window },
                ']' => .{ .command = .next_tab },
                '[' => .{ .command = .prev_tab },
                'j' => .{ .command = .next_window },
                'k' => .{ .command = .prev_window },
                '\\' => .{ .command = .detach },
                else => .noop,
            };
        }

        if (b == self.prefix_key) {
            self.waiting_for_command = true;
            return .noop;
        }

        if (b == 0x1b) { // ESC
            self.escape_state = .esc;
            self.esc_buf[0] = b;
            self.esc_len = 1;
            return .noop;
        }

        return .{ .forward = b };
    }

    fn feedEscapeByte(self: *Router, b: u8) Event {
        if (self.esc_len >= self.esc_buf.len) {
            const seq = self.emitEscAsSequence();
            self.resetEscape();
            return .{ .forward_sequence = seq };
        }

        self.esc_buf[self.esc_len] = b;
        self.esc_len += 1;

        return switch (self.escape_state) {
            .esc => switch (b) {
                '[' => blk: {
                    self.escape_state = .csi;
                    break :blk .noop;
                },
                else => blk: {
                    const seq = self.emitEscAsSequence();
                    self.resetEscape();
                    break :blk .{ .forward_sequence = seq };
                },
            },
            .csi => if (isCsiFinalByte(b)) blk: {
                const seq = self.emitEscAsSequence();
                self.resetEscape();
                break :blk .{ .forward_sequence = seq };
            } else .noop,
            .none => .noop,
        };
    }

    fn emitEscAsSequence(self: *Router) ForwardSequence {
        var seq: ForwardSequence = .{};
        const n: usize = self.esc_len;
        @memcpy(seq.buf[0..n], self.esc_buf[0..n]);
        seq.len = self.esc_len;
        seq.mouse = parseMouseSgr(seq.slice());
        return seq;
    }

    fn resetEscape(self: *Router) void {
        self.escape_state = .none;
        self.esc_len = 0;
    }
};

fn isCsiFinalByte(b: u8) bool {
    return b >= '@' and b <= '~';
}

fn parseMouseSgr(seq: []const u8) ?MouseEvent {
    if (seq.len < 6) return null;
    if (!std.mem.startsWith(u8, seq, "\x1b[<")) return null;

    const final = seq[seq.len - 1];
    if (final != 'M' and final != 'm') return null;
    const payload = seq[3 .. seq.len - 1];

    var parts = std.mem.splitScalar(u8, payload, ';');
    const b_str = parts.next() orelse return null;
    const x_str = parts.next() orelse return null;
    const y_str = parts.next() orelse return null;
    if (parts.next() != null) return null;

    const button = std.fmt.parseInt(u16, b_str, 10) catch return null;
    const x = std.fmt.parseInt(u16, x_str, 10) catch return null;
    const y = std.fmt.parseInt(u16, y_str, 10) catch return null;

    return .{
        .button = button,
        .x = x,
        .y = y,
        .pressed = final == 'M',
    };
}

test "input router forwards regular bytes" {
    const testing = std.testing;
    var r = Router{};
    const ev = r.feedByte('a');
    try testing.expectEqual(Event{ .forward = 'a' }, ev);
}

test "input router parses prefixed command" {
    const testing = std.testing;
    var r = Router{};
    try testing.expectEqual(Event.noop, r.feedByte(0x07));
    try testing.expectEqual(Event{ .command = .create_window }, r.feedByte('c'));
}

test "input router emits csi sequence as one event" {
    const testing = std.testing;
    var r = Router{};

    try testing.expectEqual(Event.noop, r.feedByte(0x1b));
    try testing.expectEqual(Event.noop, r.feedByte('['));
    const ev = r.feedByte('A');
    switch (ev) {
        .forward_sequence => |seq| {
            try testing.expectEqualStrings("\x1b[A", seq.slice());
            try testing.expect(seq.mouse == null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "input router parses sgr mouse sequence metadata" {
    const testing = std.testing;
    var r = Router{};

    const bytes = "\x1b[<0;10;20M";
    for (bytes[0 .. bytes.len - 1]) |b| {
        _ = r.feedByte(b);
    }
    const ev = r.feedByte(bytes[bytes.len - 1]);

    switch (ev) {
        .forward_sequence => |seq| {
            try testing.expectEqualStrings(bytes, seq.slice());
            try testing.expect(seq.mouse != null);
            const m = seq.mouse.?;
            try testing.expectEqual(@as(u16, 0), m.button);
            try testing.expectEqual(@as(u16, 10), m.x);
            try testing.expectEqual(@as(u16, 20), m.y);
            try testing.expect(m.pressed);
        },
        else => return error.TestUnexpectedResult,
    }
}
