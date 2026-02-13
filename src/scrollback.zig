const std = @import("std");

pub const SearchDirection = enum {
    forward,
    backward,
};

pub const SearchResult = struct {
    line_index: usize,
    line: []const u8,
};

pub const ScrollbackBuffer = struct {
    allocator: std.mem.Allocator,
    max_lines: usize,
    lines: std.ArrayListUnmanaged([]u8) = .{},
    partial_line: std.ArrayListUnmanaged(u8) = .{},
    // Number of lines currently scrolled up from the bottom.
    scroll_offset: usize = 0,

    pub fn init(allocator: std.mem.Allocator, max_lines: usize) ScrollbackBuffer {
        return .{
            .allocator = allocator,
            .max_lines = @max(@as(usize, 1), max_lines),
        };
    }

    pub fn deinit(self: *ScrollbackBuffer) void {
        for (self.lines.items) |line| self.allocator.free(line);
        self.lines.deinit(self.allocator);
        self.partial_line.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn append(self: *ScrollbackBuffer, bytes: []const u8) !void {
        for (bytes) |b| {
            if (b == '\n') {
                try self.flushPartialAsLine();
                continue;
            }
            try self.partial_line.append(self.allocator, b);
        }
    }

    pub fn scrollPageUp(self: *ScrollbackBuffer, page_lines: usize) void {
        if (self.lines.items.len == 0) return;
        const delta = @max(@as(usize, 1), page_lines);
        const max_offset = self.lines.items.len;
        self.scroll_offset = @min(max_offset, self.scroll_offset + delta);
    }

    pub fn scrollPageDown(self: *ScrollbackBuffer, page_lines: usize) void {
        const delta = @max(@as(usize, 1), page_lines);
        if (self.scroll_offset <= delta) {
            self.scroll_offset = 0;
        } else {
            self.scroll_offset -= delta;
        }
    }

    pub fn scrollHalfPageUp(self: *ScrollbackBuffer, page_lines: usize) void {
        self.scrollPageUp(@max(@as(usize, 1), page_lines / 2));
    }

    pub fn scrollHalfPageDown(self: *ScrollbackBuffer, page_lines: usize) void {
        self.scrollPageDown(@max(@as(usize, 1), page_lines / 2));
    }

    pub fn resetScroll(self: *ScrollbackBuffer) void {
        self.scroll_offset = 0;
    }

    pub fn search(self: *const ScrollbackBuffer, query: []const u8, direction: SearchDirection) ?SearchResult {
        if (query.len == 0) return null;

        return switch (direction) {
            .forward => self.searchForward(query),
            .backward => self.searchBackward(query),
        };
    }

    pub fn jumpToLine(self: *ScrollbackBuffer, line_index: usize) void {
        if (self.lines.items.len == 0) {
            self.scroll_offset = 0;
            return;
        }
        if (line_index >= self.lines.items.len) return;

        const distance_from_bottom = (self.lines.items.len - 1) - line_index;
        self.scroll_offset = distance_from_bottom;
    }

    fn flushPartialAsLine(self: *ScrollbackBuffer) !void {
        const line = try self.partial_line.toOwnedSlice(self.allocator);
        self.partial_line = .{};
        try self.lines.append(self.allocator, line);
        try self.trimToMaxLines();
    }

    fn trimToMaxLines(self: *ScrollbackBuffer) !void {
        while (self.lines.items.len > self.max_lines) {
            const removed = self.lines.orderedRemove(0);
            self.allocator.free(removed);
            if (self.scroll_offset > 0) self.scroll_offset -= 1;
        }
    }

    fn searchForward(self: *const ScrollbackBuffer, query: []const u8) ?SearchResult {
        for (self.lines.items, 0..) |line, i| {
            if (std.mem.indexOf(u8, line, query) != null) {
                return .{ .line_index = i, .line = line };
            }
        }
        return null;
    }

    fn searchBackward(self: *const ScrollbackBuffer, query: []const u8) ?SearchResult {
        var i = self.lines.items.len;
        while (i > 0) {
            i -= 1;
            const line = self.lines.items[i];
            if (std.mem.indexOf(u8, line, query) != null) {
                return .{ .line_index = i, .line = line };
            }
        }
        return null;
    }
};

test "scrollback appends lines and trims to max" {
    const testing = std.testing;
    var sb = ScrollbackBuffer.init(testing.allocator, 2);
    defer sb.deinit();

    try sb.append("a\nb\nc\n");
    try testing.expectEqual(@as(usize, 2), sb.lines.items.len);
    try testing.expectEqualStrings("b", sb.lines.items[0]);
    try testing.expectEqualStrings("c", sb.lines.items[1]);
}

test "scrollback page and half-page navigation updates offset" {
    const testing = std.testing;
    var sb = ScrollbackBuffer.init(testing.allocator, 10);
    defer sb.deinit();

    try sb.append("1\n2\n3\n4\n5\n");
    sb.scrollPageUp(4);
    try testing.expectEqual(@as(usize, 4), sb.scroll_offset);
    sb.scrollHalfPageDown(4);
    try testing.expectEqual(@as(usize, 2), sb.scroll_offset);
}

test "scrollback search and jump positions offset" {
    const testing = std.testing;
    var sb = ScrollbackBuffer.init(testing.allocator, 10);
    defer sb.deinit();

    try sb.append("alpha\nbeta\ngamma\n");
    const found = sb.search("beta", .backward) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), found.line_index);
    sb.jumpToLine(found.line_index);
    try testing.expectEqual(@as(usize, 1), sb.scroll_offset);
}
