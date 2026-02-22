const std = @import("std");

pub const Command = enum {
    create_window,
    close_window,
    open_popup,
    close_popup,
    cycle_popup,
    toggle_sidebar_panel,
    toggle_bottom_panel,
    new_tab,
    close_tab,
    next_tab,
    prev_tab,
    move_window_next_tab,
    next_window,
    prev_window,
    focus_left,
    focus_down,
    focus_up,
    focus_right,
    zoom_to_master,
    cycle_layout,
    resize_master_shrink,
    resize_master_grow,
    master_count_increase,
    master_count_decrease,
    scroll_page_up,
    scroll_page_down,
    toggle_sync_scroll,
    toggle_mouse_passthrough,
    detach,
};

pub fn commandName(cmd: Command) []const u8 {
    return @tagName(cmd);
}

pub fn parseCommandName(name: []const u8) ?Command {
    inline for (std.meta.fields(Command)) |field| {
        if (std.mem.eql(u8, name, field.name)) {
            return @field(Command, field.name);
        }
    }
    return null;
}

pub fn isValidCommandName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if ((c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_' or c == '-' or c == '.')
        {
            continue;
        }
        return false;
    }
    return true;
}

pub const Event = union(enum) {
    forward: u8,
    forward_sequence: ForwardSequence,
    command: Command,
    prefixed_key: u8,
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
    sidebar_toggle_key: u8 = 0x13, // Ctrl+S
    bottom_toggle_key: u8 = 0x02, // Ctrl+B
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
            if (b == self.sidebar_toggle_key) return .{ .command = .toggle_sidebar_panel };
            if (b == self.bottom_toggle_key) return .{ .command = .toggle_bottom_panel };
            return switch (b) {
                'c' => .{ .command = .create_window },
                'x' => .{ .command = .close_window },
                'p' => .{ .command = .open_popup },
                0x1b => .{ .command = .close_popup },
                '\t' => .{ .command = .cycle_popup },
                't' => .{ .command = .new_tab },
                'w' => .{ .command = .close_tab },
                ']' => .{ .command = .next_tab },
                '[' => .{ .command = .prev_tab },
                'm' => .{ .command = .move_window_next_tab },
                'h' => .{ .command = .focus_left },
                'j' => .{ .command = .focus_down },
                'k' => .{ .command = .focus_up },
                'l' => .{ .command = .focus_right },
                'J' => .{ .command = .next_window },
                'K' => .{ .command = .prev_window },
                '\r', '\n' => .{ .command = .zoom_to_master },
                ' ' => .{ .command = .cycle_layout },
                'H' => .{ .command = .resize_master_shrink },
                'L' => .{ .command = .resize_master_grow },
                'I' => .{ .command = .master_count_increase },
                'O' => .{ .command = .master_count_decrease },
                'u' => .{ .command = .scroll_page_up },
                'd' => .{ .command = .scroll_page_down },
                's' => .{ .command = .toggle_sync_scroll },
                'M' => .{ .command = .toggle_mouse_passthrough },
                '\\' => .{ .command = .detach },
                0x1c => .{ .command = .detach }, // Ctrl+\
                else => .{ .prefixed_key = b },
            };
        }

        if (b == 0x1c) return .{ .command = .detach }; // Ctrl+\ direct fallback

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
    if (!std.mem.startsWith(u8, seq, "\x1b[")) return null;

    const final = seq[seq.len - 1];
    if (final != 'M' and final != 'm') return null;
    var payload = seq[2 .. seq.len - 1];
    if (payload.len == 0) return null;
    // SGR mouse extension uses "<b;x;y", while some terminals emit
    // numeric CSI form "b;x;y" (urxvt-style 1015).
    if (payload[0] == '<') payload = payload[1..];
    if (payload.len == 0) return null;

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

test "input router parses detach via Ctrl+\\ byte" {
    const testing = std.testing;
    var r = Router{};
    try testing.expectEqual(Event{ .command = .detach }, r.feedByte(0x1c));
}

test "input command name roundtrip" {
    const testing = std.testing;
    const cmd: Command = .open_popup;
    const name = commandName(cmd);
    try testing.expectEqualStrings("open_popup", name);
    try testing.expectEqual(cmd, parseCommandName(name) orelse return error.TestUnexpectedResult);
}

test "input router parses layout cycle command" {
    const testing = std.testing;
    var r = Router{};
    try testing.expectEqual(Event.noop, r.feedByte(0x07));
    try testing.expectEqual(Event{ .command = .cycle_layout }, r.feedByte(' '));
}

test "input router parses zoom-to-master command" {
    const testing = std.testing;
    var r = Router{};
    try testing.expectEqual(Event.noop, r.feedByte(0x07));
    try testing.expectEqual(Event{ .command = .zoom_to_master }, r.feedByte('\r'));
}

test "input router parses master resize and count commands" {
    const testing = std.testing;
    var r = Router{};

    try testing.expectEqual(Event.noop, r.feedByte(0x07));
    try testing.expectEqual(Event{ .command = .resize_master_shrink }, r.feedByte('H'));

    try testing.expectEqual(Event.noop, r.feedByte(0x07));
    try testing.expectEqual(Event{ .command = .resize_master_grow }, r.feedByte('L'));

    try testing.expectEqual(Event.noop, r.feedByte(0x07));
    try testing.expectEqual(Event{ .command = .master_count_increase }, r.feedByte('I'));

    try testing.expectEqual(Event.noop, r.feedByte(0x07));
    try testing.expectEqual(Event{ .command = .master_count_decrease }, r.feedByte('O'));
}

test "input router parses sync-scroll toggle command" {
    const testing = std.testing;
    var r = Router{};
    try testing.expectEqual(Event.noop, r.feedByte(0x07));
    try testing.expectEqual(Event{ .command = .toggle_sync_scroll }, r.feedByte('s'));
}

test "input router parses directional focus commands" {
    const testing = std.testing;
    var r = Router{};

    try testing.expectEqual(Event.noop, r.feedByte(0x07));
    try testing.expectEqual(Event{ .command = .focus_left }, r.feedByte('h'));
    try testing.expectEqual(Event.noop, r.feedByte(0x07));
    try testing.expectEqual(Event{ .command = .focus_down }, r.feedByte('j'));
    try testing.expectEqual(Event.noop, r.feedByte(0x07));
    try testing.expectEqual(Event{ .command = .focus_up }, r.feedByte('k'));
    try testing.expectEqual(Event.noop, r.feedByte(0x07));
    try testing.expectEqual(Event{ .command = .focus_right }, r.feedByte('l'));
}

test "input router parses popup commands" {
    const testing = std.testing;
    var r = Router{};

    try testing.expectEqual(Event.noop, r.feedByte(0x07));
    try testing.expectEqual(Event{ .command = .open_popup }, r.feedByte('p'));

    try testing.expectEqual(Event.noop, r.feedByte(0x07));
    try testing.expectEqual(Event{ .command = .close_popup }, r.feedByte(0x1b));

    try testing.expectEqual(Event.noop, r.feedByte(0x07));
    try testing.expectEqual(Event{ .command = .cycle_popup }, r.feedByte('\t'));
}

test "input router parses dedicated panel toggle commands" {
    const testing = std.testing;
    var r = Router{};

    try testing.expectEqual(Event.noop, r.feedByte(0x07)); // prefix
    try testing.expectEqual(Event{ .command = .toggle_sidebar_panel }, r.feedByte(0x13)); // Ctrl+S

    try testing.expectEqual(Event.noop, r.feedByte(0x07)); // prefix
    try testing.expectEqual(Event{ .command = .toggle_bottom_panel }, r.feedByte(0x02)); // Ctrl+B
}

test "input router emits unknown prefixed key" {
    const testing = std.testing;
    var r = Router{};
    try testing.expectEqual(Event.noop, r.feedByte(0x07));
    try testing.expectEqual(Event{ .prefixed_key = 'q' }, r.feedByte('q'));
}

test "input validates command names" {
    const testing = std.testing;
    try testing.expect(isValidCommandName("toggle_sidebar"));
    try testing.expect(isValidCommandName("plugin.foo-1"));
    try testing.expect(!isValidCommandName(""));
    try testing.expect(!isValidCommandName("bad name"));
    try testing.expect(!isValidCommandName("bad:colon"));
}

test "input router parses scroll commands" {
    const testing = std.testing;
    var r = Router{};

    try testing.expectEqual(Event.noop, r.feedByte(0x07));
    try testing.expectEqual(Event{ .command = .scroll_page_up }, r.feedByte('u'));

    try testing.expectEqual(Event.noop, r.feedByte(0x07));
    try testing.expectEqual(Event{ .command = .scroll_page_down }, r.feedByte('d'));
}

test "input router parses mouse passthrough toggle command" {
    const testing = std.testing;
    var r = Router{};

    try testing.expectEqual(Event.noop, r.feedByte(0x07));
    try testing.expectEqual(Event{ .command = .toggle_mouse_passthrough }, r.feedByte('M'));
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

test "input router parses numeric csi mouse sequence metadata without angle prefix" {
    const testing = std.testing;
    var r = Router{};

    const bytes = "\x1b[0;20;5M";
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
            try testing.expectEqual(@as(u16, 20), m.x);
            try testing.expectEqual(@as(u16, 5), m.y);
            try testing.expect(m.pressed);
        },
        else => return error.TestUnexpectedResult,
    }
}
