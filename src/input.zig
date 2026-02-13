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
    command: Command,
    noop,
};

pub const Router = struct {
    prefix_key: u8 = 0x07, // Ctrl+G
    waiting_for_command: bool = false,

    pub fn feedByte(self: *Router, b: u8) Event {
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

        return .{ .forward = b };
    }
};

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
